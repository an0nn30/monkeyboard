//! A bounded noisy-channel decoder for a segment that the keyboard still owns.
//! Surface observations are independent of the local word/class trigram model.
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, CStr};
use std::sync::LazyLock;

type Id = u16;
const BEAM: usize = 12;
const LIMIT: usize = 18;
const MAX_BYTES: usize = 320;

#[derive(Clone, Copy)]
struct Entry {
    text: &'static str,
    display: &'static str,
    count: f32,
    class: Id,
}

struct Model {
    lex: Vec<Entry>,
    ids: HashMap<&'static str, Id>,
    // Keys with at most two deleted letters retrieve candidates for transposition,
    // substitution and boundary-corrupted spellings without scanning the lexicon.
    deletes: HashMap<String, Vec<Id>>,
    observed: HashMap<&'static str, Vec<(Id, Id, f32)>>,
    tables: Vec<HashMap<u64, f32>>,
    grams: HashMap<u16, Vec<Id>>,
    ordinary: HashSet<&'static str>,
    total: f32,
    start: Id,
}

fn deletions(w: &str, depth: usize, mut visit: impl FnMut(&str)) {
    visit(w);
    let mut one = String::with_capacity(w.len());
    let mut two = String::with_capacity(w.len());
    for i in 0..w.len() {
        if i > 0 && w.as_bytes()[i] == w.as_bytes()[i - 1] {
            continue;
        }
        one.clear();
        one.push_str(&w[..i]);
        one.push_str(&w[i + 1..]);
        visit(&one);
        if depth > 1 {
            for j in i..one.len() {
                if j > i && one.as_bytes()[j] == one.as_bytes()[j - 1] {
                    continue;
                }
                two.clear();
                two.push_str(&one[..j]);
                two.push_str(&one[j + 1..]);
                visit(&two);
            }
        }
    }
}

static MODEL: LazyLock<Model> = LazyLock::new(|| {
    let mut lex = vec![Entry {
        text: "",
        display: "",
        count: 1.,
        class: 0,
    }];
    let mut ids = HashMap::new();
    let mut deletes = HashMap::<_, Vec<_>>::new();
    let mut total = 0.;
    for l in include_str!("../model/denoise22/vocab.tsv").lines() {
        let mut fields = l.split('\t');
        let word = fields.next().unwrap();
        let display = fields.next().unwrap();
        let count = fields.next().unwrap().parse().unwrap();
        let class = fields.next().unwrap().parse().unwrap();
        let id = lex.len() as Id;
        lex.push(Entry {
            text: word,
            display,
            count,
            class,
        });
        ids.insert(word, id);
        total += count;
        if word != "^" && word != "$" && word.is_ascii() && word.len() <= 32 {
            deletions(word, if word.len() >= 4 { 2 } else { 1 }, |key| {
                let bucket = deletes.entry(key.to_owned()).or_default();
                if bucket.last() != Some(&id) {
                    bucket.push(id);
                }
            });
        }
    }
    let mut grams = HashMap::<_, Vec<_>>::new();
    for (i, w) in lex.iter().enumerate().skip(1) {
        for pair in w.text.as_bytes().windows(2) {
            let code = u16::from_be_bytes([pair[0], pair[1]]);
            let values = grams.entry(code).or_default();
            if values.last() != Some(&(i as Id)) {
                values.push(i as Id);
            }
        }
    }
    let mut observed: HashMap<_, Vec<_>> = HashMap::new();
    for line in include_str!("../model/denoise22/channel.tsv").lines() {
        let mut vals = line.split('\t');
        let raw = vals.next().unwrap();
        let mut pair = vals
            .next()
            .unwrap()
            .split(',')
            .map(|x| x.parse::<Id>().unwrap());
        let a = pair.next().unwrap();
        let b = pair.next().unwrap_or(0);
        let count = vals.next().unwrap().parse::<f32>().unwrap();
        observed.entry(raw).or_default().push((a, b, count));
    }
    let mut data = &include_bytes!("../model/denoise22/local.bin")[..];
    let mut tables = vec![];
    while !data.is_empty() {
        let n = u32::from_le_bytes(data[..4].try_into().unwrap()) as usize;
        data = &data[4..];
        let mut table = HashMap::with_capacity(n);
        for row in data[..12 * n].chunks_exact(12) {
            let key = u64::from_le_bytes(row[..8].try_into().unwrap());
            let count = u32::from_le_bytes(row[8..].try_into().unwrap()) as f32;
            table.insert(key, count);
        }
        tables.push(table);
        data = &data[12 * n..];
    }
    let ordinary = include_str!("../model/words.tsv")
        .lines()
        .filter_map(|l| l.split_once('\t').map(|x| x.0))
        .chain(include_str!("../model/semantics/vocab.txt").lines())
        .chain(include_str!("../model/denoise22/literals.txt").lines())
        .collect();
    let start = ids["^"];
    Model {
        lex,
        ids,
        deletes,
        observed,
        tables,
        grams,
        ordinary,
        total,
        start,
    }
});

fn two(a: Id, b: Id) -> u64 {
    ((a as u64) << 16) | b as u64
}
fn three(a: Id, b: Id, c: Id) -> u64 {
    (two(a, b) << 16) | c as u64
}

impl Model {
    fn term(&self, table: usize, key: u64) -> f32 {
        self.tables[table].get(&key).copied().unwrap_or_default()
    }

    fn transition(&self, p: Id, a: Id, w: Id) -> f32 {
        if w == 0 {
            return -19.0;
        }
        let word = self.lex[w as usize];
        let unigram = word.count / self.total;
        if a == 0 {
            return (unigram * 0.64 + 0.00012).ln();
        }
        let (prev, last) = (self.lex[p as usize], self.lex[a as usize]);
        let cla = self.term(2, last.class as u64);
        let clw = self.term(2, word.class as u64);
        let classprob =
            (self.term(3, two(last.class, word.class)) + 6. * clw / self.total) / (cla + 6.);
        let cc = self.term(3, two(prev.class, last.class));
        let cprob =
            (self.term(4, three(prev.class, last.class, word.class)) + 6. * classprob) / (cc + 6.);
        let clustered = cprob * word.count / clw.max(1.);
        let big = self.term(0, two(a, w));
        let back = (big + 7. * unigram) / (last.count + 7.);
        let hist = self.term(0, two(p, a));
        let tr = (self.term(1, three(p, a, w)) + 8. * back) / (hist + 8.);
        (0.57 * tr + 0.36 * clustered + 0.063 * back + 0.007 * unigram + 0.000025).ln()
    }
}

#[derive(Clone, Copy)]
struct Edge {
    a: Id,
    b: Id,
    consume: usize,
    emission: f32,
    observed: bool,
    support: f32,
}

fn near_cost(a: u8, b: u8) -> f32 {
    const KEYS: [&[u8]; 3] = [b"qwertyuiop", b"asdfghjkl", b"zxcvbnm"];
    let pos = |k| {
        KEYS.iter().enumerate().find_map(|(y, row)| {
            row.iter()
                .position(|&c| c == k)
                .map(|x| (x as i32 * 4 + y as i32 * 2, y as i32))
        })
    };
    if let (Some((x, y)), Some((u, v))) = (pos(a), pos(b)) {
        if (x - u).abs() <= 5 && (y - v).abs() <= 1 {
            return 1.;
        }
    }
    1.55
}

// Encode up to two letters into a dense coordinate. At 32 symbols the
// character-channel table uses under one megabyte and allocates once per process.
fn symbol(c: u8) -> usize {
    match c {
        b'a'..=b'z' => (c - b'a' + 1) as usize,
        39 => 27,
        b'-' => 28,
        _ => 29,
    }
}
fn chunk(s: &[u8]) -> usize {
    match s {
        [] => 0,
        [a] => symbol(*a),
        [a, b] => 32 * symbol(*a) + symbol(*b),
        _ => unreachable!(),
    }
}
const CHUNK_WIDTH: usize = 960;
static CHUNKS: LazyLock<Vec<u8>> = LazyLock::new(|| {
    let mut table = vec![225u8; CHUNK_WIDTH * CHUNK_WIDTH];
    for l in include_str!("../model/denoise22/chunks.tsv").lines() {
        let mut f = l.split('\t');
        let x = chunk(f.next().unwrap().as_bytes());
        let y = chunk(f.next().unwrap().as_bytes());
        table[x * CHUNK_WIDTH + y] =
            (f.next().unwrap().parse::<f32>().unwrap() * 25.0).round() as u8;
    }
    table
});

// Weighted optimal string alignment, with adjacent swaps, repeated keys,
// and missing apostrophes distinguished from distant substitutions.
fn distance(s: &[u8], t: &[u8], cap: f32) -> f32 {
    if s == t {
        return 0.;
    }
    if s.len().abs_diff(t.len()) as f32 > cap + 1. {
        return 99.;
    }
    let table = &*CHUNKS;
    let mut gold1 = [0; 34];
    let mut gold2 = [0; 34];
    for j in 1..=t.len() {
        gold1[j] = symbol(t[j - 1]) * CHUNK_WIDTH;
        if j >= 2 {
            gold2[j] = chunk(&t[j - 2..j]) * CHUNK_WIDTH;
        }
    }
    let mut prev2 = [0.0_f32; 34];
    let mut prev = [0.0_f32; 34];
    let mut row = [0.0_f32; 34];
    for j in 1..=t.len() {
        prev[j] = prev[j - 1] + if t[j - 1] == 39 { 0.58 } else { 1.15 };
    }
    for i in 1..=s.len() {
        let x = s[i - 1];
        let obs1 = symbol(x);
        let obs2 = if i >= 2 { chunk(&s[i - 2..i]) } else { 0 };
        let rem = if i > 1 && s[i - 2] == x { 0.70 } else { 1.22 };
        row[0] = prev[0] + rem;
        let mut low = row[0];
        for j in 1..=t.len() {
            let y = t[j - 1];
            let add = if y == 39 {
                0.58
            } else if j > 1 && t[j - 2] == y {
                0.80
            } else {
                1.13
            };
            let sub = if x == y {
                0.
            } else {
                near_cost(x, y).min(table[gold1[j] + obs1] as f32 * 0.04)
            };
            row[j] = (prev[j] + rem).min(row[j - 1] + add).min(prev[j - 1] + sub);
            if j >= 2 {
                row[j] = row[j].min(prev[j - 2] + (table[gold2[j] + obs1] as f32 * 0.04));
            }
            if i >= 2 {
                row[j] = row[j].min(prev2[j - 1] + (table[gold1[j] + obs2] as f32 * 0.04));
            }
            if i >= 2 && j >= 2 {
                row[j] = row[j].min(prev2[j - 2] + (table[gold2[j] + obs2] as f32 * 0.04));
            }
            if i >= 2 && j >= 2 && x == t[j - 2] && y == s[i - 2] {
                row[j] = row[j].min(prev2[j - 2] + 0.76);
            }
            low = low.min(row[j]);
        }
        if low > cap + 1.55 {
            return 99.;
        }
        std::mem::swap(&mut prev, &mut prev2);
        std::mem::swap(&mut prev, &mut row);
    }
    prev[t.len()]
}

fn channel(d: f32) -> f32 {
    -2.35 - 2.95 * d
}
fn retain(edges: &mut Vec<Edge>, edge: Edge) {
    if let Some(prev) = edges
        .iter_mut()
        .find(|e| e.a == edge.a && e.b == edge.b && e.consume == edge.consume)
    {
        prev.emission = prev.emission.max(edge.emission);
        prev.observed |= edge.observed;
        prev.support = prev.support.max(edge.support);
    } else {
        edges.push(edge);
    }
}

fn candidates(m: &Model, w: &str, cap: f32, depth: usize) -> Vec<(Id, f32)> {
    if w.is_empty() || w.len() > 32 || !w.is_ascii() {
        return vec![];
    }
    let mut ids = vec![];
    deletions(w, depth, |key| {
        if let Some(v) = m.deletes.get(key) {
            ids.extend_from_slice(v);
        }
    });
    if depth > 2 {
        for pair in w.as_bytes().windows(2) {
            if let Some(found) = m.grams.get(&u16::from_be_bytes([pair[0], pair[1]])) {
                ids.extend(found);
            }
        }
    }
    ids.sort_unstable();
    ids.dedup();
    ids.into_iter()
        .filter_map(|i| {
            let t = m.lex[i as usize].text;
            if t.len().abs_diff(w.len()) > depth {
                return None;
            }
            let d = distance(w.as_bytes(), t.as_bytes(), cap);
            (d <= cap).then_some((i, d))
        })
        .collect()
}

fn rank(m: &Model, edge: &Edge) -> f32 {
    edge.emission
        + 0.46
            * (if edge.b == 0 {
                m.lex[edge.a as usize].count
            } else {
                m.term(0, two(edge.a, edge.b))
            })
            .max(1.)
            .ln()
}

fn observed(m: &Model, w: &str, edges: &mut Vec<Edge>, consumed: usize) {
    if let Some(obs) = m.observed.get(w) {
        for &(a, b, n) in obs {
            let support = if b == 0 {
                m.lex[a as usize].count
            } else {
                m.term(0, two(a, b))
            };
            let emit = ((n + 0.1) / (support + 1.)).min(0.8).ln();
            retain(
                edges,
                Edge {
                    a,
                    b,
                    consume: consumed,
                    emission: emit,
                    observed: true,
                    support: n,
                },
            );
        }
    }
}

struct Token<'a> {
    raw: &'a str,
    word: String,
    start: usize,
    end: usize,
    locked: bool,
}

// Leave surrounding punctuation and whitespace in the original string. A lexical
// apostrophe, hyphen or time colon is part of the token when used internally.
fn tokenize(s: &str) -> Vec<Token<'_>> {
    let chars: Vec<_> = s.char_indices().collect();
    let mut out = vec![];
    let mut i = 0;
    while i < chars.len() {
        if !chars[i].1.is_alphanumeric() {
            i += 1;
            continue;
        }
        let start = chars[i].0;
        i += 1;
        while i < chars.len() {
            let c = chars[i].1;
            let bridge = matches!(c, '\'' | '’' | '-' | ':' | ';')
                && chars.get(i + 1).is_some_and(|p| p.1.is_alphanumeric());
            let trailing = matches!(c, '\'' | '’')
                && !s[..start].ends_with(['\'', '‘', '’'])
                && MODEL.observed.contains_key(
                    s[start..chars[i].0 + c.len_utf8()]
                        .to_ascii_lowercase()
                        .as_str(),
                );
            if !c.is_alphanumeric() && !bridge && !trailing {
                break;
            }
            i += 1;
        }
        let end = chars.get(i).map_or(s.len(), |p| p.0);
        let raw = &s[start..end];
        let word = raw.replace('’', "'").to_ascii_lowercase();
        let lower = raw.chars().skip(1).all(|x| !x.is_uppercase());
        let known = MODEL
            .ids
            .get(word.as_str())
            .is_some_and(|&id| MODEL.lex[id as usize].display == raw);
        let mixed = !lower && !known;
        let established_boundary = word.is_ascii()
            && raw.char_indices().skip(1).any(|(j, c)| {
                if !c.is_uppercase() {
                    return false;
                }
                let (a, b) = word.split_at(j);
                match (MODEL.ids.get(a), MODEL.ids.get(b)) {
                    (Some(&a), Some(&b)) => MODEL.term(0, two(a, b)) >= 3.,
                    _ => false,
                }
            });
        let before = &s[..start];
        let after = &s[end..];
        let identifier = before.ends_with(['@', '#', '_', '/', '='])
            || after.starts_with(['@', '_', '='])
            || before.ends_with('.')
                && before[..before.len() - 1]
                    .chars()
                    .next_back()
                    .is_some_and(char::is_alphanumeric)
            || after.starts_with('.')
                && after[1..].chars().next().is_some_and(char::is_alphanumeric);
        let locked = !word.is_ascii()
            || word.len() > 32
            || raw.contains([':', '-'])
            || raw.bytes().all(|c| c.is_ascii_digit())
            || raw.bytes().any(|c| c.is_ascii_digit())
                && !MODEL.observed.contains_key(word.as_str())
            || word.len() > 1 && raw.bytes().all(|c| c.is_ascii_uppercase())
            || mixed
                && !established_boundary
                && !MODEL.observed.contains_key(word.as_str())
                && !MODEL.ids.contains_key(word.as_str())
            || identifier;
        out.push(Token {
            raw,
            word,
            start,
            end,
            locked,
        });
    }
    out
}

fn literal_likely(m: &Model, t: &Token<'_>) -> bool {
    t.locked
        || m.ids.contains_key(t.word.as_str())
        || m.ordinary.contains(t.word.as_str())
        || t.raw.len() > 2
            && t.raw.chars().next().is_some_and(char::is_uppercase)
            && !m.observed.contains_key(t.word.as_str())
}

fn supported(m: &Model, ts: &[Token<'_>], i: usize, a: Id) -> bool {
    let observed = |j: usize| {
        ts.get(j)
            .and_then(|t| m.ids.get(t.word.as_str()))
            .copied()
            .unwrap_or(0)
    };
    let left = if i == 0 { m.start } else { observed(i - 1) };
    let right = observed(i + 1);
    let l = m.term(0, two(left, a));
    let r = m.term(0, two(a, right));
    if left != 0 && right != 0 && m.term(1, three(left, a, right)) >= 3. {
        return true;
    }
    if i >= 2 && m.term(1, three(observed(i - 2), left, a)) >= 5. {
        return true;
    }
    if i + 2 < ts.len() && m.term(1, three(a, right, observed(i + 2))) >= 5. {
        return true;
    }
    l >= 8. && r >= 8.
}

fn edges(m: &Model, tokens: &[Token<'_>], i: usize, raw: &str) -> Vec<Edge> {
    let t = &tokens[i];
    let id = m.ids.get(t.word.as_str()).copied().unwrap_or(0);
    let literal = Edge {
        a: id,
        b: 0,
        consume: 1,
        emission: 0.,
        observed: false,
        support: 0.,
    };
    let mut edges = vec![literal];
    if t.locked {
        return edges;
    }
    observed(m, &t.word, &mut edges, 1);
    let cap = if t.word.len() >= 6 {
        2.85
    } else if t.word.len() >= 4 {
        2.48
    } else {
        1.62
    };
    let expand = id == 0 && t.word.len() >= 4;
    let depth = if expand {
        3
    } else if t.word.len() >= 4 {
        2
    } else {
        1
    };
    for (a, d) in candidates(m, &t.word, if expand { 4.4 } else { cap }, depth) {
        if d > 0. {
            retain(
                &mut edges,
                Edge {
                    a,
                    b: 0,
                    consume: 1,
                    emission: channel(d),
                    observed: false,
                    support: 0.,
                },
            );
        }
    }

    if id == 0 && t.word.len() >= 4 && t.word.len() <= 32 && t.word.is_ascii() {
        for j in 1..t.word.len() {
            let (left, right) = t.word.split_at(j);
            let ll = m.ids.get(left).copied();
            let rr = m.ids.get(right).copied();
            // A corrupt boundary can also carry a typo in one of its halves.
            // Enumerate near matches only with a lexically anchored other half.
            if ll.is_none() && rr.is_none() && (left.len() < 2 || right.len() < 2) {
                continue;
            }
            let l = if let Some(k) = ll {
                vec![(k, 0.)]
            } else {
                candidates(
                    m,
                    left,
                    if rr.is_some() { 2.3 } else { 1.6 },
                    if rr.is_some() { 2 } else { 1 },
                )
            };
            let r = if let Some(k) = rr {
                vec![(k, 0.)]
            } else {
                candidates(
                    m,
                    right,
                    if ll.is_some() { 2.3 } else { 1.6 },
                    if ll.is_some() { 2 } else { 1 },
                )
            };
            for &(a, dl) in &l {
                for &(b, dr) in &r {
                    let bi = m.term(0, two(a, b));
                    if bi < 1. || dl + dr > 2.65 {
                        continue;
                    }
                    let emission = -3.45
                        - if dl + dr > 0. {
                            1.2 + 2.9 * (dl + dr)
                        } else {
                            0.
                        };
                    retain(
                        &mut edges,
                        Edge {
                            a,
                            b,
                            consume: 1,
                            emission,
                            observed: false,
                            support: 0.,
                        },
                    );
                }
            }
        }
    }
    if let Some(t2) = tokens.get(i + 1) {
        if !t2.locked
            && &raw[t.end..t2.start] == " "
            && t.word.len() + t2.word.len() <= 32
            && (id == 0 || !m.ids.contains_key(t2.word.as_str()))
        {
            let combined = format!("{}{}", t.word, t2.word);
            let spelling = format!("{} {}", t.word, t2.word);
            observed(m, &spelling, &mut edges, 2);
            for (a, d) in candidates(m, &combined, 1.6, 1) {
                retain(
                    &mut edges,
                    Edge {
                        a,
                        b: 0,
                        consume: 2,
                        emission: -4.2 - if d > 0. { 1.5 + 2.95 * d } else { 0. },
                        observed: false,
                        support: 0.,
                    },
                );
            }
        }
    }
    edges.sort_by(|x, y| rank(m, y).total_cmp(&rank(m, x)));
    edges.truncate(28);
    if !edges
        .iter()
        .any(|e| e.a == id && e.b == 0 && e.consume == 1)
    {
        edges.push(literal);
    }
    edges
}

#[derive(Clone, Copy)]
struct Path {
    score: f32,
    p: Id,
    last: Id,
    picks: [u8; LIMIT],
}

fn push_beam(list: &mut Vec<Path>, path: Path) {
    if list.len() == BEAM && list.last().unwrap().score >= path.score {
        return;
    }
    if let Some(k) = list
        .iter()
        .position(|old| old.p == path.p && old.last == path.last)
    {
        if list[k].score >= path.score {
            return;
        }
        list.remove(k);
    }
    let at = list.partition_point(|old| old.score >= path.score);
    list.insert(at, path);
    if list.len() > BEAM {
        list.pop();
    }
}

fn surface(m: &Model, a: Id, raw: &str, first: bool) -> String {
    if a == 0 {
        return raw.to_owned();
    }
    let w = m.lex[a as usize];
    if raw.replace('’', "'").eq_ignore_ascii_case(w.text) {
        // Correct the case of words consistently capitalized inside messages,
        // but preserve the user's conversational sentence casing.
        if !w
            .display
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_uppercase)
            || raw == w.display
        {
            return raw.to_owned();
        }
    }
    let mut display = w.display.to_owned();
    if first && display.is_ascii() && !display.is_empty() {
        display[..1].make_ascii_uppercase();
    }
    if raw.contains('’') {
        display = display.replace('\'', "’");
    }
    display
}

pub(super) fn attestation(raw: &str, intended: &str) -> f32 {
    MODEL.observed.get(raw).and_then(|rows| rows.iter().find(|(a,b,_)|
        *b == 0 && MODEL.lex[*a as usize].text == intended)).map_or(0., |row| row.2)
}

/// Observed single-word errors; the consumer still needs independent context.
pub(super) fn observed_single(raw: &str) -> impl Iterator<Item = (&'static str, f32)> + '_ {
    MODEL.observed.get(raw).into_iter().flatten()
        .filter(|(_, second, _)| *second == 0)
        .map(|(first, _, hits)| (MODEL.lex[*first as usize].text, *hits))
}

pub(super) fn decode(input: &str) -> Option<String> {
    if input.len() > MAX_BYTES {
        return None;
    }
    let ts = tokenize(input);
    if ts.is_empty() || ts.len() > LIMIT {
        return None;
    }
    let m = &*MODEL;
    let clean_segment = ts.iter().all(|t| literal_likely(m, t));

    // In unfamiliar text give the literal more weight. Multiple observed
    // typos in a segment are evidence that this is inside the training domain.
    let sparse_context = ts.len() > 1
        && ts
            .iter()
            .filter(|t| m.ids.contains_key(t.word.as_str()))
            .count()
            * 3
            < ts.len()
        && ts
            .iter()
            .filter(|t| m.observed.contains_key(t.word.as_str()))
            .count()
            < 2;
    let choices: Vec<_> = (0..ts.len()).map(|i| edges(m, &ts, i, input)).collect();
    let mut stacks = vec![Vec::new(); ts.len() + 1];
    stacks[0].push(Path {
        score: 0.,
        p: 0,
        last: m.start,
        picks: [0; LIMIT],
    });
    for i in 0..ts.len() {
        let paths = std::mem::take(&mut stacks[i]);
        for path in paths {
            for (j, e) in choices[i].iter().enumerate() {
                let (mut p, mut last) = (path.last, e.a);
                let mut s = path.score + e.emission + m.transition(path.p, path.last, e.a);
                if e.b != 0 {
                    s += m.transition(path.last, e.a, e.b);
                    (p, last) = (e.a, e.b);
                }
                let t = &ts[i];
                if e.a == 0 {
                    if m.ordinary.contains(t.word.as_str()) || t.locked {
                        s += 12.;
                    } else if sparse_context {
                        s += 4.;
                    }
                }
                if e.consume != 1 || e.b != 0 || m.lex[e.a as usize].text != t.word && e.a != 0 {
                    let known =
                        m.ids.contains_key(t.word.as_str()) || m.ordinary.contains(t.word.as_str());
                    s -= if known { 2.9 } else { 0.2 };
                    if clean_segment {
                        // In fluent-looking text a real-word edit needs a
                        // repeatedly observed confusion and a large context margin.
                        if e.consume != 1
                            || e.b != 0
                            || e.support < 2.
                                && (m.ids.contains_key(t.word.as_str())
                                    || sparse_context
                                    || !supported(m, &ts, i, e.a))
                        {
                            continue;
                        }
                        if let Some(&literal) = m.ids.get(t.word.as_str()) {
                            let left = i
                                .checked_sub(1)
                                .and_then(|j| m.ids.get(ts[j].word.as_str()))
                                .copied()
                                .unwrap_or(m.start);
                            let right = ts
                                .get(i + 1)
                                .and_then(|t| m.ids.get(t.word.as_str()))
                                .copied()
                                .unwrap_or(0);
                            if m.term(6, three(left, literal, right)) >= 1.
                                || m.term(5, two(left, literal)) >= 6.
                                    && (right == 0 || m.term(5, two(literal, right)) >= 3.)
                            {
                                continue;
                            }
                        }
                        s -= if e.support >= 8. {
                            1.5
                        } else if e.support >= 2. {
                            6.5
                        } else {
                            3.
                        };
                    }
                    if !e.observed
                        && e.consume == 1
                        && e.b == 0
                        && t.word.len() <= 4
                        && e.emission < -6.5
                        && m.lex[e.a as usize].text.len() == t.word.len()
                    {
                        continue;
                    }
                    if !m.ids.contains_key(t.word.as_str())
                        && !e.observed
                        && e.consume == 1
                        && e.b == 0
                    {
                        let strong = supported(m, &ts, i, e.a);
                        if m.ordinary.contains(t.word.as_str()) && !strong {
                            s -= 2.5;
                        }
                        if sparse_context && !strong && e.emission < -4.8 {
                            continue;
                        }
                        if sparse_context && !strong && t.word.len() < 5 && e.emission < -6.2 {
                            continue;
                        }

                        if t.raw.chars().next().is_some_and(char::is_uppercase)
                            && t.raw.chars().skip(1).all(char::is_lowercase)
                            && (e.emission < -7.8
                                || m.lex[e.a as usize].text.as_bytes().first()
                                    != t.word.as_bytes().first())
                        {
                            continue;
                        }
                    }
                }
                let mut picks = path.picks;
                picks[i] = j as u8;
                push_beam(
                    &mut stacks[i + e.consume],
                    Path {
                        score: s,
                        p,
                        last,
                        picks,
                    },
                );
            }
        }
    }
    let best = stacks.last()?.first()?;
    let mut out = String::with_capacity(input.len() + 8);
    let mut has_edit = false;
    let mut j = 0;
    while j < ts.len() {
        let e = choices[j][best.picks[j] as usize];
        if e.consume != 1 || e.b != 0 || e.a != 0 && m.lex[e.a as usize].text != ts[j].word {
            has_edit = true;
            break;
        }
        j += e.consume;
    }
    let mut consumed = 0;
    let mut i = 0;
    while i < ts.len() {
        let t = &ts[i];
        let e = choices[i][best.picks[i] as usize];
        let last = &ts[i + e.consume - 1];
        out.push_str(&input[consumed..t.start]);
        let original = &input[t.start..last.end];
        let same = e.b == 0 && e.consume == 1 && (e.a == 0 || m.lex[e.a as usize].text == t.word);
        let singleton = ts.len() == 1;
        if i == 0
            && has_edit
            && !clean_segment
            && same
            && e.a != 0
            && t.raw.is_ascii()
            && t.raw.bytes().next().is_some_and(|c| c.is_ascii_lowercase())
        {
            let mut start = original.to_string();
            start[..1].make_ascii_uppercase();
            out.push_str(&start);
        } else if t.locked
            || clean_segment && same
            || singleton
                && (m.ordinary.contains(t.word.as_str())
                    || m.ids.contains_key(t.word.as_str())
                    || t.word.len() < 3)
        {
            out.push_str(original);
        } else if same && (e.a == 0 || singleton) {
            out.push_str(original);
        } else {
            out.push_str(&surface(
                m,
                e.a,
                t.raw,
                i == 0 || t.raw.chars().next().is_some_and(char::is_uppercase),
            ));
            if e.b != 0 {
                out.push(' ');
                out.push_str(&surface(m, e.b, "", false));
            }
        }
        consumed = last.end;
        i += e.consume;
    }
    out.push_str(&input[consumed..]);
    (out != input).then_some(out)
}

/// Returns 1 for a changed surface, 0 to retain the exact literal, or -1 for
/// invalid UTF-8, invalid pointers or insufficient output capacity.
#[no_mangle]
pub unsafe extern "C" fn mb_denoise22_v1(
    typed: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if typed.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    let Ok(input) = CStr::from_ptr(typed).to_str() else {
        return -1;
    };
    let Some(result) = decode(input) else {
        *out = 0;
        return 0;
    };
    if result.len() >= capacity {
        *out = 0;
        return -1;
    }
    std::ptr::copy_nonoverlapping(result.as_ptr(), out.cast(), result.len());
    *out.add(result.len()) = 0;
    1
}
