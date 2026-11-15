//! Review residual edits against a two-sided word context. The original
//! keystrokes bound the candidate distance when an earlier decoder changed a word.
use std::{
    collections::{HashMap, HashSet},
    sync::LazyLock,
};
type Id = u16;

struct Entry {
    word: &'static str,
    display: &'static str,
    domain: f32,
    public: f32,
}
struct Data {
    lex: Vec<Entry>,
    ids: HashMap<&'static str, Id>,
    grams: HashMap<u16, Vec<Id>>,
    one: HashMap<String, Vec<Id>>,
    ctx: Vec<HashMap<u32, u16>>,
    ordinary: HashSet<&'static str>,
    contexts: HashMap<(Id, i8), Vec<Id>>,
    chunks: Vec<u8>,
    casing: HashMap<u32, &'static str>,
    observed: HashMap<&'static str, Vec<(Id, f32)>>,
}

const WIDTH: usize = 960;
fn sym(c: u8) -> usize {
    if c.is_ascii_lowercase() {
        (c - b'a' + 1) as usize
    } else if c == 39 {
        27
    } else if c == b'-' {
        28
    } else {
        29
    }
}
fn code(s: &[u8]) -> usize {
    match s {
        [] => 0,
        [a] => sym(*a),
        [a, b] => sym(*a) * 32 + sym(*b),
        _ => 0,
    }
}
fn pair(a: Id, b: Id) -> u32 {
    ((a as u32) << 16) | b as u32
}
impl Data {
    fn load() -> Self {
        let mut lex = vec![Entry {
            word: "",
            display: "",
            domain: 0.,
            public: 0.,
        }];
        let mut ids = HashMap::new();
        let mut grams = HashMap::<u16, Vec<Id>>::new();
        let mut one = HashMap::<String, Vec<Id>>::new();
        for l in include_str!("../model/refine26/vocab.tsv").lines() {
            let mut f = l.split('\t');
            let word = f.next().unwrap();
            let id = lex.len() as Id;
            ids.insert(word, id);
            let e = Entry {
                word,
                display: f.next().unwrap(),
                domain: f.next().unwrap().parse().unwrap(),
                public: f.next().unwrap().parse().unwrap(),
            };
            if word.is_ascii() && word.len() <= 28 && word != "^" {
                for g in word.as_bytes().windows(2) {
                    let bucket = grams.entry(u16::from_be_bytes([g[0], g[1]])).or_default();
                    if bucket.last() != Some(&id) {
                        bucket.push(id);
                    }
                }
                for i in 0..word.len() {
                    if i > 0 && word.as_bytes()[i] == word.as_bytes()[i - 1] {
                        continue;
                    }
                    let k = format!("{}{}", &word[..i], &word[i + 1..]);
                    one.entry(k).or_default().push(id);
                }
            }
            lex.push(e);
        }
        let mut ctx = vec![];
        let mut neighbors = HashMap::<(Id, i8), Vec<(u16, Id)>>::new();
        let mut bytes = &include_bytes!("../model/refine26/context.bin")[..];
        while !bytes.is_empty() {
            let n = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
            bytes = &bytes[4..];
            let mut h = HashMap::with_capacity(n);
            let k = (ctx.len() + 1) as i8;
            for row in bytes[..n * 6].chunks_exact(6) {
                let key = u32::from_le_bytes(row[..4].try_into().unwrap());
                let n = u16::from_le_bytes(row[4..].try_into().unwrap());
                let a = (key >> 16) as Id;
                let b = key as Id;
                h.insert(key, n);
                if n >= 6 {
                    neighbors.entry((a, k)).or_default().push((n, b));
                    neighbors.entry((b, -k)).or_default().push((n, a));
                }
            }
            ctx.push(h);
            bytes = &bytes[n * 6..];
        }
        let contexts = neighbors
            .into_iter()
            .map(|(k, mut v)| {
                v.sort_unstable_by(|a, b| b.cmp(a));
                (k, v.into_iter().take(24).map(|p| p.1).collect())
            })
            .collect();
        let ordinary = include_str!("../model/semantics/vocab.txt")
            .lines()
            .chain(include_str!("../model/denoise22/literals.txt").lines())
            .chain(
                include_str!("../model/words.tsv")
                    .lines()
                    .filter_map(|s| s.split_once('\t').map(|p| p.0)),
            )
            .collect();
        let casing = include_str!("../model/refine26/case.tsv")
            .lines()
            .filter_map(|s| {
                let mut f = s.split('\t');
                Some((pair(*ids.get(f.next()?)?, *ids.get(f.next()?)?), f.next()?))
            })
            .collect();
        let den_vocab: Vec<_> = std::iter::once("")
            .chain(
                include_str!("../model/denoise22/vocab.tsv")
                    .lines()
                    .map(|s| s.split('\t').next().unwrap()),
            )
            .collect();
        let mut observed = HashMap::<&str, Vec<(Id, f32)>>::new();
        for row in include_str!("../model/denoise22/channel.tsv").lines() {
            let mut parts = row.split('\t');
            let raw = parts.next().unwrap();
            if let Ok(i) = parts.next().unwrap().parse::<usize>() {
                if let Some(&idx) = ids.get(den_vocab[i]) {
                    let n = parts.next().unwrap().parse::<f32>().unwrap();
                    observed.entry(raw).or_default().push((idx, n));
                }
            }
        }
        let mut chunks = vec![250; WIDTH * WIDTH];
        for l in include_str!("../model/denoise22/chunks.tsv").lines() {
            let mut f = l.split('\t');
            let a = code(f.next().unwrap().as_bytes());
            let b = code(f.next().unwrap().as_bytes());
            chunks[a * WIDTH + b] = (f.next().unwrap().parse::<f32>().unwrap() * 25.).round() as u8;
        }
        Self {
            lex,
            ids,
            grams,
            one,
            ctx,
            ordinary,
            contexts,
            chunks,
            casing,
            observed,
        }
    }
    fn id(&self, s: &str) -> Id {
        *self.ids.get(s).unwrap_or(&0)
    }
    fn n(&self, a: Id, b: Id, d: usize) -> f32 {
        self.ctx[d - 1].get(&pair(a, b)).copied().unwrap_or(0) as f32 * 0.25
    }
    fn prior(&self, id: Id) -> f32 {
        let e = &self.lex[id as usize];
        1. + e.domain + e.public * 0.28
    }
    fn count(&self, a: Id, b: Id, d: usize) -> f32 {
        if a == 0 || b == 0 {
            return 0.;
        }
        let n = self.n(a, b, d);
        if n == 0. {
            return 0.;
        }
        (1. + n * 400000. / (self.prior(a) * self.prior(b)))
            .ln()
            .min(10.)
            * (n / (n + 1.)).sqrt()
    }
    fn dist(&self, obs: &str, clean: &str) -> f32 {
        if obs == clean {
            return 0.;
        }
        if obs.len() > 30 || clean.len() > 30 {
            return 99.;
        }
        let s = obs.as_bytes();
        let t = clean.as_bytes();
        let (mut prev, mut older, mut row) = ([0f32; 32], [0f32; 32], [0f32; 32]);
        for j in 1..=t.len() {
            prev[j] = prev[j - 1] + if t[j - 1] == 39 { 0.45 } else { 1. };
        }
        for i in 1..=s.len() {
            let x = s[i - 1];
            let o1 = sym(x);
            let o2 = if i > 1 { code(&s[i - 2..i]) } else { 0 };
            let del = if i > 1 && s[i - 2] == x { 0.62 } else { 1.05 };
            row[0] = prev[0] + del;
            for j in 1..=t.len() {
                let y = t[j - 1];
                let k = sym(y) * WIDTH;
                let add = if y == 39 {
                    0.44
                } else if j > 1 && t[j - 2] == y {
                    0.72
                } else {
                    1.
                };
                let sub = if x == y {
                    0.
                } else {
                    1.35_f32.min(self.chunks[k + o1] as f32 * 0.04)
                };
                let mut v = (prev[j] + del).min(row[j - 1] + add).min(prev[j - 1] + sub);
                if i > 1 {
                    v = v.min(older[j - 1] + self.chunks[k + o2] as f32 * 0.04);
                }
                if j > 1 {
                    let k2 = code(&t[j - 2..j]) * WIDTH;
                    v = v.min(prev[j - 2] + self.chunks[k2 + o1] as f32 * 0.04);
                    if i > 1 {
                        v = v.min(older[j - 2] + self.chunks[k2 + o2] as f32 * 0.04);
                        if x == t[j - 2] && s[i - 2] == y {
                            v = v.min(older[j - 2] + 0.64);
                        }
                    }
                }
                row[j] = v;
            }
            std::mem::swap(&mut prev, &mut older);
            std::mem::swap(&mut prev, &mut row);
        }
        prev[t.len()]
    }
}
static MODEL: LazyLock<Data> = LazyLock::new(Data::load);

struct Token<'a> {
    word: String,
    surface: &'a str,
    start: usize,
    end: usize,
    protected: bool,
}
fn tokens(s: &str) -> Vec<Token<'_>> {
    let chars: Vec<_> = s.char_indices().collect();
    let mut ans = vec![];
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
            if !c.is_alphanumeric()
                && !(matches!(c, '\'' | '’' | ';' | '-' | ':')
                    && chars.get(i + 1).is_some_and(|t| t.1.is_alphanumeric()))
            {
                break;
            }
            i += 1;
        }
        let end = chars.get(i).map_or(s.len(), |p| p.0);
        let v = &s[start..end];
        let word = v.to_lowercase().replace('’', "'");
        let before = &s[..start];
        let after = &s[end..];
        let protected = !word.is_ascii()
            || word.len() > 27
            || v.bytes().any(|c| c.is_ascii_digit())
            || v.len() > 1 && v.bytes().all(|c| c.is_ascii_uppercase())
            || before.ends_with(['@', '#', '_', '/'])
            || after.starts_with(['@', '_', '/'])
            || before.ends_with('.')
                && before[..before.len() - 1]
                    .chars()
                    .next_back()
                    .is_some_and(char::is_alphanumeric)
            || after.starts_with('.')
                && after[1..].chars().next().is_some_and(char::is_alphanumeric);
        ans.push(Token {
            word,
            surface: v,
            start,
            end,
            protected,
        });
    }
    ans
}

struct Surround {
    left: [Id; 3],
    right: [Id; 3],
}
impl Surround {
    fn new(ids: &[Id], i: usize, n: usize) -> Self {
        Self {
            left: std::array::from_fn(|j| {
                if j == i {
                    1
                } else {
                    i.checked_sub(j + 1)
                        .and_then(|k| ids.get(k))
                        .copied()
                        .unwrap_or(0)
                }
            }),
            right: std::array::from_fn(|j| ids.get(i + n + j).copied().unwrap_or(0)),
        }
    }
    fn scores(&self, m: &Data, a: Id, b: Id) -> (f32, f32) {
        let mut sum = 0.;
        let mut observed = 0.;
        for (j, w) in [1., 0.61, 0.40].iter().enumerate() {
            let l = m.count(self.left[j], a, j + 1);
            let r = m.count(if b != 0 { b } else { a }, self.right[j], j + 1);
            sum += *w * (l + r);
            observed += if l > 1. { *w } else { 0. } + if r > 1. { *w } else { 0. };
        }
        if b != 0 {
            sum += 0.68 * m.count(a, b, 1);
        }
        (sum, observed)
    }
}
#[derive(Clone, Copy)]
struct Pick {
    a: Id,
    b: Id,
    consume: usize,
    score: f32,
}
fn neighbors(m: &Data, w: &str, ctx: &Surround) -> Vec<Id> {
    let mut ids = vec![];
    if let Some(v) = m.observed.get(w) {
        ids.extend(v.iter().map(|p| p.0));
    }
    for (j, (l, r)) in ctx.left.iter().zip(ctx.right).enumerate() {
        if let Some(v) = m.contexts.get(&(*l, j as i8 + 1)) {
            ids.extend(v);
        }
        if let Some(v) = m.contexts.get(&(r, -(j as i8) - 1)) {
            ids.extend(v);
        }
    }
    for j in 0..w.len() {
        let part = format!("{}{}", &w[..j], &w[j + 1..]);
        if let Some(k) = m.ids.get(part.as_str()) {
            ids.push(*k);
        }
        if let Some(v) = m.one.get(&part) {
            ids.extend(v);
        }
    }
    if let Some(v) = m.one.get(w) {
        ids.extend(v);
    }
    // Within the domain a single matching character pair is sufficient to
    // propose a distant phonetic variant. Public vocabulary uses closer edits.
    if w.len() > 3 {
        for p in w.as_bytes().windows(2) {
            if let Some(v) = m.grams.get(&u16::from_be_bytes([p[0], p[1]])) {
                ids.extend(v.iter().filter(|&&i| m.lex[i as usize].domain > 0.));
            }
        }
    }
    ids.sort_unstable();
    ids.dedup();
    ids
}

fn choose(
    m: &Data,
    ts: &[Token<'_>],
    ids: &[Id],
    i: usize,
    raw: &str,
    suspect: bool,
) -> Option<Pick> {
    let t = &ts[i];
    if t.protected
        || !raw.is_ascii()
        || raw.len() > 27
        || raw.contains(';') && !m.observed.contains_key(raw)
    {
        return None;
    }
    let id = ids[i];
    let known = id != 0 || m.ordinary.contains(t.word.as_str());
    let context = Surround::new(ids, i, 1);
    let (old_ctx, _) = context.scores(m, id, 0);
    let domain = m.lex[id as usize].domain;
    let strongcase = t
        .surface
        .as_bytes()
        .first()
        .is_some_and(u8::is_ascii_uppercase)
        && t.surface.bytes().skip(1).all(|b| b.is_ascii_lowercase());
    let changed = raw != t.word;
    if id != 0 && old_ctx >= 8. && !changed {
        return None;
    }
    let base = old_ctx + if id != 0 { 0.35 * m.prior(id).ln() } else { 0. };
    // A well-attested apostrophe omission/mis-hit is not an edit to the
    // lexical letters. This channel often outranks a different function word.
    if id == 0 || domain == 0. {
        if let Some(v) = m.observed.get(raw) {
            for &(a, n) in v {
                let w = &m.lex[a as usize];
                let apostrophes = w.word.replace('\'', "");
                if n >= 8.
                    && w.word.contains('\'')
                    && (apostrophes == raw || raw.replace(';', "'") == w.word)
                    && (!known || context.scores(m, a, 0).0 >= old_ctx + 2.)
                {
                    return Some(Pick {
                        a,
                        b: 0,
                        consume: 1,
                        score: 0.,
                    });
                }
            }
        }
    }
    let base_dist = if changed { m.dist(raw, &t.word) } else { 0. };
    let mut best = Pick {
        a: id,
        b: 0,
        consume: 1,
        score: base,
    };
    let mut next = base - 2.;
    let mut consider = |a: Id, b: Id, consume: usize, dist: f32, ctx: &Surround| {
        let (support, neighbors) = ctx.scores(m, a, b);
        let evidence = m
            .observed
            .get(raw)
            .and_then(|v| v.iter().find(|p| p.0 == a))
            .map_or(0., |p| p.1);
        let bonus = if b == 0 && evidence >= 2. {
            (1. + evidence).ln().min(5.) * 1.25
        } else {
            0.
        };
        let score = support + bonus + 0.35 * m.prior(a).ln()
            - (dist - base_dist) * 2.65
            - if known {
                if domain > 0. {
                    5.0
                } else {
                    3.5
                }
            } else {
                0.8
            }
            - if b != 0 { 4.4 } else { 0. }
            - if consume > 1 { 5. } else { 0. };
        let need = if consume == 2 && dist < 0.1 && (id == 0 || ids[i + 1] == 0) {
            0.8
        } else if known {
            if domain > 0. {
                2.45
            } else {
                1.85
            }
        } else if strongcase {
            1.35
        } else {
            0.80
        };
        if !suspect && evidence < 3. {
            let boundary = b != 0 && dist < 1.9 && m.n(a, b, 1) >= 2. && neighbors >= 1.0
                || consume == 2 && dist < 0.1 && neighbors >= 1.0;
            if !boundary || ts.len() < 3 || !suspect && m.ordinary.contains(raw) {
                if known || strongcase || t.word.contains(['-', '\'']) {
                    return;
                }
                if dist > 1.6 || neighbors < 1.8 || support < 10. {
                    return;
                }
            }
        }
        if !suspect && known && consume == 1 && (score < base + 8. || old_ctx >= 4.) {
            return;
        }
        if neighbors < need || score <= base + 1.1 {
            return;
        }
        if best.a == a && best.b == b && best.consume == consume {
            best.score = best.score.max(score);
            return;
        }
        if score > best.score {
            next = best.score;
            best = Pick {
                a,
                b,
                consume,
                score,
            };
        } else {
            next = next.max(score);
        }
    };
    for a in neighbors(m, raw, &context) {
        let w = &m.lex[a as usize];
        if a == id || w.word == "^" || w.word.len().abs_diff(raw.len()) > 4 {
            continue;
        }
        if (id == 0 && !changed || known)
            && strongcase
            && !w.display.starts_with(char::is_uppercase)
            && i > 0
        {
            continue;
        }
        let d = m.dist(raw, w.word);
        let cap = if domain > 0. {
            1.60
        } else if known {
            2.4
        } else if w.domain == 0. {
            1.36
        } else {
            4.8
        };
        if d > cap {
            continue;
        }
        if w.domain == 0. && w.public < 4. {
            continue;
        }
        consider(a, 0, 1, d, &context);
    }
    if !known && !changed {
        for j in 1..raw.len() {
            let (l, r) = raw.split_at(j);
            let a = m.id(l);
            let b = m.id(r);
            if a != 0 && b != 0 && m.n(a, b, 1) >= 3. {
                consider(a, b, 1, 0., &context);
            }
            if a != 0 && r.len() >= 2 {
                for &b in m.contexts.get(&(a, 1)).into_iter().flatten() {
                    let w = m.lex[b as usize].word;
                    if w.len().abs_diff(r.len()) > 2 {
                        continue;
                    }
                    let d = m.dist(r, w);
                    if d <= 2.4 {
                        consider(a, b, 1, d + 0.35, &context);
                    }
                }
            }
            if b != 0 && l.len() >= 2 {
                for &a in m.contexts.get(&(b, -1)).into_iter().flatten() {
                    let w = m.lex[a as usize].word;
                    if w.len().abs_diff(l.len()) > 2 {
                        continue;
                    }
                    let d = m.dist(l, w);
                    if d <= 2.4 {
                        consider(a, b, 1, d + 0.35, &context);
                    }
                }
            }
        }
    }
    if let Some(t2) = ts.get(i + 1) {
        if !t2.protected && t.end + 1 == t2.start && (id == 0 || ids[i + 1] == 0) {
            let fused = format!("{}{}", t.word, t2.word);
            if fused.len() < 27 {
                let ctx = Surround::new(ids, i, 2);
                for a in neighbors(m, &fused, &ctx) {
                    let w = m.lex[a as usize].word;
                    if w.len().abs_diff(fused.len()) > 1 {
                        continue;
                    }
                    let d = m.dist(&fused, w);
                    if d <= 1.4 {
                        consider(a, 0, 2, d, &ctx);
                    }
                }
            }
        }
    }
    (best.score > base + if known { 2.2 } else { 0.7 }
        && best.score - next > if known { 1.2 } else { 0.38 })
    .then_some(best)
}

pub(super) fn refine(raw: &str, proposal: &str) -> Option<String> {
    if raw.len() > 300 || proposal.len() > 300 {
        return None;
    }
    let m = &*MODEL;
    let ts = tokens(proposal);
    if ts.len() < 2 || ts.len() > 18 {
        return None;
    }
    let original = tokens(raw);
    let aligned = original.len() == ts.len();
    let mut ids: Vec<_> = ts.iter().map(|t| m.id(&t.word)).collect();
    let unknown = ts
        .iter()
        .filter(|t| m.id(&t.word) == 0 && !m.ordinary.contains(t.word.as_str()) && !t.protected)
        .count();
    let suspect = raw != proposal
        || unknown >= 2
            && ts.len() > 3
            && ids
                .iter()
                .filter(|&&id| m.lex[id as usize].domain > 0.)
                .count()
                * 2
                >= ts.len()
        || ts.iter().any(|t| {
            m.observed
                .get(t.word.as_str())
                .is_some_and(|v| v.iter().any(|p| p.1 >= 8.))
                && m.lex[m.id(&t.word) as usize].domain == 0.
        });
    let mut edits = vec![];
    let mut i = 0;
    while i < ts.len() {
        let t = &ts[i];
        let source = if aligned {
            original[i].word.as_str()
        } else {
            &t.word
        };
        if let Some(e) = choose(m, &ts, &ids, i, source, suspect)
            .filter(|e| e.consume == 1 || &proposal[t.end..ts[i + 1].start] == " ")
        {
            let w = &m.lex[e.a as usize];
            let mut surface = w.display.to_owned();
            if i == 0 && !t.protected && (suspect || e.b != 0) && surface.is_ascii() {
                surface[..1].make_ascii_uppercase();
            }
            if t.surface.starts_with(char::is_uppercase) && surface.is_ascii() {
                surface[..1].make_ascii_uppercase();
            }
            if e.b != 0 {
                surface.push(' ');
                surface.push_str(m.lex[e.b as usize].display);
            }
            if t.surface.contains('’') {
                surface = surface.replace('\'', "’");
            }
            edits.push((t.start, ts[i + e.consume - 1].end, surface));
            ids[i] = e.a;
            i += e.consume;
            continue;
        }
        let preferred_case = ts
            .get(i + 1)
            .and_then(|_| m.casing.get(&pair(ids[i], ids[i + 1])))
            .copied();
        if suspect && !t.protected && t.surface.bytes().all(|c| c.is_ascii_lowercase()) {
            if let Some(standard) = preferred_case {
                if standard != t.surface {
                    edits.push((t.start, t.end, standard.to_owned()));
                    i += 1;
                    continue;
                }
            }
        }
        if !t.protected
            && ids[i] != 0
            && t.surface.bytes().filter(|c| c.is_ascii_uppercase()).count() == 2
            && t.surface
                .as_bytes()
                .first()
                .is_some_and(u8::is_ascii_uppercase)
            && t.surface.as_bytes()[1].is_ascii_uppercase()
            && t.surface.bytes().skip(2).all(|c| c.is_ascii_lowercase())
        {
            let mut d = m.lex[ids[i] as usize].display.to_owned();
            if i == 0 {
                d[..1].make_ascii_uppercase();
            }
            if d != t.surface && Surround::new(&ids, i, 1).scores(m, ids[i], 0).0 >= 5.0 {
                edits.push((t.start, t.end, d));
            }
        }
        i += 1;
    }
    if edits.is_empty() {
        return None;
    }
    if suspect
        && !ts[0].protected
        && ts[0]
            .surface
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_lowercase)
        && edits.first().is_none_or(|e| e.0 != ts[0].start)
    {
        let mut first = ts[0].surface.to_owned();
        first[..1].make_ascii_uppercase();
        edits.insert(0, (ts[0].start, ts[0].end, first));
    }
    let mut out = proposal.to_owned();
    for (start, end, s) in edits.into_iter().rev() {
        out.replace_range(start..end, &s);
    }
    Some(out)
}
