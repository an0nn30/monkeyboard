//! Independent local posterior over word and capitalization surfaces. Candidate
//! words come from observed context pairs or a public-language edit index.
use std::{
    collections::{HashMap, HashSet},
    sync::LazyLock,
};
type Id = u16;
const OFFSETS: [(isize, isize); 9] = [
    (-1, 1),
    (-2, -1),
    (1, 2),
    (-2, 1),
    (-1, 2),
    (-1, 0),
    (1, 0),
    (-2, 0),
    (2, 0),
];
struct Entry {
    word: &'static str,
    normal: &'static str,
    initial: &'static str,
    domain: f32,
    public: f32,
}
struct Model {
    lex: Vec<Entry>,
    ids: HashMap<&'static str, Id>,
    deletes: HashMap<String, Vec<Id>>,
    // Each value is an offset to compact word/count records in the read-only binary.
    slots: Vec<HashMap<u32, (usize, u8)>>,
    protected: HashSet<&'static str>,
    observed: HashMap<&'static str, Vec<(Id, f32)>>,
}
const DATA: &[u8] = include_bytes!("../model/surface31/context.bin");
fn get16(p: usize) -> u16 {
    u16::from_le_bytes(DATA[p..p + 2].try_into().unwrap())
}
fn get32(p: usize) -> u32 {
    u32::from_le_bytes(DATA[p..p + 4].try_into().unwrap())
}
impl Model {
    fn load() -> Self {
        let mut lex = Vec::new();
        let mut ids = HashMap::new();
        let mut deletes = HashMap::<String, Vec<Id>>::new();
        for l in include_str!("../model/surface31/vocab.tsv").lines() {
            let mut f = l.split('\t');
            let word = f.next().unwrap();
            let i = lex.len() as Id;
            ids.insert(word, i);
            lex.push(Entry {
                word,
                domain: f.next().unwrap().parse().unwrap(),
                public: f.next().unwrap().parse().unwrap(),
                normal: f.next().unwrap(),
                initial: f.next().unwrap(),
            });
            if i > 1 && word.is_ascii() && word.len() < 25 {
                for j in 0..word.len() {
                    if j > 0 && word.as_bytes()[j] == word.as_bytes()[j - 1] {
                        continue;
                    }
                    let k = format!("{}{}", &word[..j], &word[j + 1..]);
                    deletes.entry(k).or_default().push(i);
                }
            }
        }
        let mut slots = vec![];
        let mut p = 0;
        for _ in OFFSETS {
            let n = get32(p);
            p += 4;
            let mut slot = HashMap::with_capacity(n as usize);
            for _ in 0..n {
                let k = get32(p);
                let count = DATA[p + 4];
                p += 5;
                slot.insert(k, (p, count));
                p += count as usize * 4;
            }
            slots.push(slot);
        }
        let vok: Vec<_> = std::iter::once("")
            .chain(
                include_str!("../model/denoise22/vocab.tsv")
                    .lines()
                    .map(|s| s.split('\t').next().unwrap()),
            )
            .collect();
        let mut observed = HashMap::<&str, Vec<(Id, f32)>>::new();
        for s in include_str!("../model/denoise22/channel.tsv").lines() {
            let mut it = s.split('\t');
            let raw = it.next().unwrap();
            if let Ok(i) = it.next().unwrap().parse::<usize>() {
                if let Some(&w) = ids.get(vok[i]) {
                    observed
                        .entry(raw)
                        .or_default()
                        .push((w, it.next().unwrap().parse().unwrap()));
                }
            }
        }
        Self {
            lex,
            ids,
            deletes,
            slots,
            protected: include_str!("../model/surface31/protect.txt")
                .lines()
                .collect(),
            observed,
        }
    }
    fn id(&self, w: &str) -> Id {
        *self.ids.get(w).unwrap_or(&0)
    }
}
static MODEL: LazyLock<Model> = LazyLock::new(Model::load);
struct Token<'a> {
    s: &'a str,
    w: String,
    a: usize,
    b: usize,
    locked: bool,
}
fn tokens(s: &str) -> Vec<Token<'_>> {
    let bytes: Vec<_> = s.char_indices().collect();
    let mut i = 0;
    let mut v = vec![];
    while i < bytes.len() {
        if !bytes[i].1.is_alphanumeric() {
            i += 1;
            continue;
        }
        let a = bytes[i].0;
        i += 1;
        while i < bytes.len() {
            let c = bytes[i].1;
            if !c.is_alphanumeric()
                && !(matches!(c, '\'' | '’' | '–' | '-' | ';' | ':')
                    && bytes.get(i + 1).is_some_and(|b| b.1.is_alphanumeric()))
            {
                break;
            }
            i += 1;
        }
        let b = bytes.get(i).map_or(s.len(), |t| t.0);
        let raw = &s[a..b];
        let w = raw.to_lowercase().replace('’', "'");
        let bef = &s[..a];
        let aft = &s[b..];
        let locked = w.len() > 30
            || raw.chars().any(char::is_numeric)
            || raw.len() > 1 && raw.bytes().all(|b| b.is_ascii_uppercase())
            || bef.ends_with(['@', '#', '/', '_'])
            || aft.starts_with(['@', '/', '_'])
            || bef.ends_with('.')
                && bef[..bef.len() - 1]
                    .chars()
                    .next_back()
                    .is_some_and(char::is_alphanumeric)
            || aft.starts_with('.') && aft[1..].chars().next().is_some_and(char::is_alphanumeric);
        v.push(Token {
            s: raw,
            a,
            b,
            w,
            locked,
        });
    }
    v
}
fn fold(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ä' | 'ã' | 'å' => 'a',
        'é' | 'è' | 'ê' | 'ë' => 'e',
        'ü' | 'û' | 'ú' | 'ù' => 'u',
        'í' | 'ì' | 'î' | 'ï' => 'i',
        'ó' | 'ò' | 'ô' | 'ö' | 'õ' => 'o',
        'ñ' => 'n',
        'ç' => 'c',
        _ => c,
    }
}
fn distance(a: &str, b: &str) -> f32 {
    let s: Vec<_> = a.chars().map(fold).collect();
    let t: Vec<_> = b.chars().map(fold).collect();
    if s.len() > 31 || t.len() > 31 {
        return 99.;
    }
    let mut r = [0f32; 33];
    let mut prev = [0f32; 33];
    let mut old = [0f32; 33];
    for j in 1..=t.len() {
        prev[j] = prev[j - 1] + if t[j - 1] == '\'' { 0.35 } else { 1. };
    }
    for i in 1..=s.len() {
        let x = s[i - 1];
        let del = if i > 1 && x == s[i - 2] { 0.7 } else { 1. };
        r[0] = prev[0] + del;
        for j in 1..=t.len() {
            let y = t[j - 1];
            let add = if y == '\'' {
                0.35
            } else if j > 1 && y == t[j - 2] {
                0.7
            } else {
                1.
            };
            let sub = if x == y {
                0.
            } else if x == ';' && y == '\'' {
                0.38
            } else {
                1.05
            };
            r[j] = (r[j - 1] + add).min(prev[j] + del).min(prev[j - 1] + sub);
            if j > 1 && i > 1 && x == t[j - 2] && y == s[i - 2] {
                r[j] = r[j].min(old[j - 2] + 0.7);
            }
        }
        std::mem::swap(&mut old, &mut prev);
        std::mem::swap(&mut r, &mut prev);
    }
    prev[t.len()]
}

#[derive(Clone, Copy, Default)]
struct Evidence {
    score: f32,
    joint: f32,
    unary: f32,
    patterns: u8,
}
fn evidence(m: &Model, ids: &[Id], i: usize, consumed: usize) -> HashMap<Id, Evidence> {
    let at = |offset: isize| {
        let pos = if offset > 0 {
            i as isize + offset + (consumed as isize - 1)
        } else {
            i as isize + offset
        };
        if pos == -1 {
            1
        } else if pos >= 0 {
            ids.get(pos as usize).copied().unwrap_or(0)
        } else {
            0
        }
    };
    let mut ev = HashMap::<Id, Evidence>::new();
    for (k, &(a, b)) in OFFSETS.iter().enumerate() {
        let x = at(a);
        let y = if b == 0 { 0 } else { at(b) };
        if x == 0 || b != 0 && y == 0 {
            continue;
        }
        let key = ((x as u32) << 16) | y as u32;
        let Some(&(p, n)) = m.slots[k].get(&key) else {
            continue;
        };
        let total: f32 = (0..n as usize)
            .map(|j| get16(p + 4 * j + 2) as f32 * 0.5)
            .sum();
        for j in 0..n as usize {
            let z = p + 4 * j;
            let w = get16(z);
            let count = get16(z + 2) as f32 * 0.5;
            let e = &m.lex[w as usize];
            let lift = ((count + 0.05) * 150000.
                / ((total + 2.) * (22. + e.domain + 0.25 * e.public)))
                .ln()
                .max(0.)
                .min(8.);
            let val = lift * (count / (count + 1.)).sqrt() * (count / (total + 1.)).powf(0.22);
            let target = ev.entry(w).or_default();
            if b != 0 {
                target.joint = target.joint.max(val);
                if count >= 2. {
                    target.patterns += 1;
                }
                target.score += val * 0.25;
            } else {
                target.unary = target.unary.max(val);
                target.score += val * 0.24;
            }
        }
    }
    for t in ev.values_mut() {
        t.score += t.joint + t.unary * 0.45;
    }
    ev
}

fn candidates(m: &Model, raw: &str, ev: &HashMap<Id, Evidence>) -> Vec<Id> {
    let mut v: Vec<_> = ev.keys().copied().collect();
    if let Some(o) = m.observed.get(raw) {
        v.extend(o.iter().map(|p| p.0));
    }
    if raw.is_ascii() && raw.len() <= 30 {
        if let Some(r) = m.deletes.get(raw) {
            v.extend(r);
        }
        for j in 0..raw.len() {
            let k = format!("{}{}", &raw[..j], &raw[j + 1..]);
            if let Some(r) = m.deletes.get(&k) {
                v.extend(r);
            }
            if let Some(&w) = m.ids.get(k.as_str()) {
                v.push(w);
            }
        }
    }
    v.sort_unstable();
    v.dedup();
    v
}

// The public lexicon covers words never used as targets in the paired corpus.
// Recover an isolated one-edit out-of-vocabulary spelling only when there is
// a unique close candidate, or one with much stronger population support.
fn protected(m: &Model, s: &str) -> bool {
    if m.protected.contains(s) || s.contains(['\'', '-']) {
        return true;
    }
    for suffix in ["s", "es", "ed", "ing", "ly"] {
        if let Some(stem) = s.strip_suffix(suffix) {
            if m.protected.contains(stem) || m.id(stem) != 0 {
                return true;
            }
        }
    }
    false
}
fn lexical(m: &Model, raw: &str, t: &Token<'_>, damaged: bool) -> Option<(Id, f32)> {
    if t.w != raw
        || m.id(raw) != 0
        || raw.len() < 4
        || t.locked
        || raw.contains(';')
        || protected(m, raw)
    {
        return None;
    }
    let upper = t.s.chars().next().is_some_and(char::is_uppercase);
    let mut best = (0, 0f32);
    let mut next = 0f32;
    for id in candidates(m, raw, &HashMap::new()) {
        let w = &m.lex[id as usize];
        if w.word.len().abs_diff(raw.len()) > 1 || w.public < 2. && w.domain < 3. {
            continue;
        }
        let d = distance(raw, w.word);
        if d > 1.06
            || upper
                && (w.word.as_bytes().first() != raw.as_bytes().first()
                    || !damaged && !w.normal.starts_with(char::is_uppercase))
        {
            continue;
        }
        let sc = w.public.min(200.) + w.domain.min(120.) * 0.45 + 4.;
        let x = sc / (0.2 + d).powf(3.);
        if x > best.1 {
            next = best.1;
            best = (id, x)
        } else {
            next = next.max(x);
        }
    }
    (best.0 != 0
        && best.1 >= if raw.len() >= 6 { 3.0 } else { 5.0 }
        && best.1 > next * if raw.len() >= 6 { 2.0 } else { 5.0 })
    .then_some(best)
}
fn decide(
    m: &Model,
    raw: &str,
    display: &Token<'_>,
    i: usize,
    ev: &HashMap<Id, Evidence>,
    damaged: bool,
) -> Option<(Id, f32)> {
    let id = m.id(&display.w);
    let known = id != 0;
    let old = ev.get(&id).copied().unwrap_or_default();
    if display.locked
        || raw == display.w && (raw.contains('\'') || !damaged && protected(m, raw))
        || raw.contains(';') && !m.observed.contains_key(raw)
    {
        return None;
    }
    let unchanged = raw == display.w;
    let base = old.score
        + if known {
            if unchanged {
                5.
            } else {
                2.3
            }
        } else {
            0.
        };
    if unchanged && known && (old.joint > 3. || old.score > 9.) {
        return None;
    }
    let best_old = if unchanged {
        0.
    } else {
        distance(raw, &display.w)
    };
    let mut best = (0, base);
    let mut runner = base - 0.3;
    for w in candidates(m, raw, ev) {
        if w == id || w <= 1 {
            continue;
        }
        let e = &m.lex[w as usize];
        let stats = ev.get(&w).copied().unwrap_or_default();
        let d = distance(raw, e.word);
        let good = m
            .observed
            .get(raw)
            .and_then(|v| v.iter().find(|p| p.0 == w))
            .map_or(0., |p| p.1);
        if !unchanged && known && d > best_old + 0.40 && good < 3. {
            continue;
        }
        if unchanged && known && good < 2. && (stats.patterns < 2 || old.joint > 1.) {
            continue;
        }
        if d > 4.2 && good < 2. || known && unchanged && d > 1.65 && good < 4. {
            continue;
        }
        let apostrophe = good >= 5. && e.word.replace('\'', "") == raw.replace(';', "");
        let name = display.s.chars().next().is_some_and(char::is_uppercase)
            && display.s.chars().skip(1).all(char::is_lowercase);
        if unchanged
            && !damaged
            && name
            && (e.word.as_bytes().first() != raw.as_bytes().first() || d > 1.45)
            && !apostrophe
        {
            continue;
        }
        if unchanged
            && !damaged
            && known
            && !apostrophe
            && (stats.patterns < 2 || stats.score < 14. || old.score > 2.)
        {
            continue;
        }
        if !damaged
            && !apostrophe
            && stats.joint < 3.
            && (stats.unary < 3.5 || d > 1.05 || known || name)
        {
            continue;
        }
        if d > 2. && good == 0. && stats.joint < 3. {
            continue;
        }
        if stats.score < 2. && !apostrophe && !(damaged && !known && e.public >= 5. && d <= 1.) {
            continue;
        }
        if name && i > 0 && !e.normal.starts_with(char::is_uppercase) && !damaged {
            continue;
        }
        let score = stats.score
            + 0.37 * (e.domain * 0.12 + e.public + 1.).ln().min(7.)
            + (good + 1.).ln().min(6.) * 0.85
            - (d - best_old) * 2.9
            - if !known && unchanged && name { 2. } else { 0. };
        if score > best.1 {
            runner = best.1;
            best = (w, score);
        } else {
            runner = runner.max(score);
        }
    }
    let gap = best.1 - runner;
    (best.0 != 0
        && gap > if known { 2.35 } else { 1.1 }
        && best.1 - base > if known { 3. } else { 1.05 })
    .then_some((best.0, gap))
}

// Review a missing/extra word boundary only with a strongly supported
// lexical cloze on both sides of the revised slot. Emit exactly one space
// for splits, and only consume an original ASCII space for joins.
fn boundary(
    m: &Model,
    ts: &[Token<'_>],
    ids: &[Id],
    i: usize,
    display: &str,
    damaged: bool,
) -> Option<(usize, String)> {
    let t = &ts[i];
    if t.locked || !t.w.is_ascii() || protected(m, &t.w) || t.w.contains(';') {
        return None;
    }
    let mut best = (0.0, 0, String::new());
    let mut runner = 0.0_f32;
    let mut offer = |score: f32, n: usize, text: String| {
        if score > best.0 {
            runner = best.0;
            best = (score, n, text);
        } else {
            runner = runner.max(score);
        }
    };
    if ids[i] == 0 && t.w.len() >= 5 {
        for j in 1..t.w.len() {
            let (s1, s2) = t.w.split_at(j);
            let a = m.id(s1);
            let b = m.id(s2);
            if a <= 1 || b <= 1 {
                continue;
            }
            let mut expanded = ids.to_vec();
            expanded[i] = a;
            expanded.insert(i + 1, b);
            let x = evidence(m, &expanded, i, 1)
                .get(&a)
                .copied()
                .unwrap_or_default();
            let y = evidence(m, &expanded, i + 1, 1)
                .get(&b)
                .copied()
                .unwrap_or_default();
            let support = x.score + y.score;
            if (x.joint > 2. || y.joint > 2.)
                && x.score.min(y.score) > 1.5
                && support > if damaged { 10. } else { 17. }
            {
                let first = if i == 0 {
                    m.lex[a as usize].initial
                } else {
                    m.lex[a as usize].normal
                };
                offer(
                    support,
                    1,
                    format!("{} {}", first, m.lex[b as usize].normal),
                );
            }
        }
    }
    if let Some(t2) = ts.get(i + 1) {
        if !t2.locked && &display[t.b..t2.a] == " " && (ids[i] == 0 || ids[i + 1] == 0) {
            let fused = format!("{}{}", t.w, t2.w);
            let w = m.id(&fused);
            if w > 1 {
                let e = evidence(m, ids, i, 2).get(&w).copied().unwrap_or_default();
                let word = &m.lex[w as usize];
                if (e.joint > 2. || e.unary > 3.) && e.score > if damaged { 3.5 } else { 6.5 }
                    || t.w.len() >= 2
                        && t2.w.len() >= 2
                        && word.public >= 7.
                        && ids[i] == 0
                        && ids[i + 1] == 0
                {
                    offer(
                        e.score + 8.,
                        2,
                        if i == 0 { word.initial } else { word.normal }.to_owned(),
                    );
                }
            }
        }
    }
    (best.1 != 0 && best.0 - runner > 1.5).then_some((best.1, best.2))
}
pub(super) fn refine(raw: &str, display: &str) -> Option<String> {
    if raw.len() > 300 || display.len() > 300 {
        return None;
    }
    let ts = tokens(display);
    if ts.len() < 2 || ts.len() > 18 {
        return None;
    }
    let orig = tokens(raw);
    let align = orig.len() == ts.len();
    let m = &*MODEL;
    let ids: Vec<_> = ts.iter().map(|t| m.id(&t.w)).collect();
    let known = ids
        .iter()
        .filter(|&&w| w != 0 && m.lex[w as usize].domain > 0.)
        .count();
    let damaged = raw != display
        || ts.iter().any(|t| {
            !t.locked
                && m.id(&t.w) == 0
                && m.observed
                    .get(t.w.as_str())
                    .is_some_and(|v| v.iter().any(|p| p.1 >= 5.))
        });
    let mut edits = vec![];
    let mut skip = 0;
    for (i, t) in ts.iter().enumerate() {
        if i < skip {
            continue;
        }
        if t.locked {
            continue;
        }
        let source = if align { &orig[i].w } else { &t.w };
        if let Some((consume, mut expanded)) = boundary(m, &ts, &ids, i, display, damaged) {
            if i == 0 && t.s.starts_with(char::is_uppercase) && expanded.is_ascii() {
                expanded[..1].make_ascii_uppercase();
            }
            edits.push((t.a, ts[i + consume - 1].b, expanded));
            skip = i + consume;
            continue;
        }
        let e = evidence(m, &ids, i, 1);
        let chosen =
            decide(m, source, t, i, &e, damaged).or_else(|| lexical(m, source, t, damaged));
        let w = chosen.map_or(ids[i], |v| v.0);
        if w == 0 {
            continue;
        }
        let v = &m.lex[w as usize];
        let stats = e.get(&w).copied().unwrap_or_default();
        let mut surface = if i == 0 { v.initial } else { v.normal }.to_owned();
        if i == 0 && surface.is_ascii() && t.s.starts_with(char::is_uppercase) {
            surface[..1].make_ascii_uppercase();
        }
        if chosen.is_none() {
            if t.s == surface
                || v.domain == 0.
                || !damaged
                    && t.s.to_lowercase() == t.s
                    && !v.normal.starts_with(char::is_uppercase)
            {
                continue;
            }
            // With a reliable lexical context we can restore an accidental
            // second capital or a name, or undo a new case change by the decoder.
            let mixed = t.s.chars().skip(1).any(char::is_uppercase);
            let is_name = v.normal.chars().next().is_some_and(char::is_uppercase);
            if !damaged && !mixed && !(is_name && known + 1 >= ts.len() && stats.joint > 3.) {
                continue;
            }
            if stats.joint < 2. && stats.unary < 3. || !damaged && !is_name && !mixed {
                continue;
            }
            if !mixed && !is_name && i > 0 && (!align || orig[i].s != surface) {
                continue;
            }
        } else if i == 0 && t.s.chars().next().is_some_and(char::is_uppercase) && surface.is_ascii()
        {
            surface[..1].make_ascii_uppercase();
        }
        if t.s.contains('’') {
            surface = surface.replace('\'', "’");
        }
        if surface != t.s {
            edits.push((t.a, t.b, surface));
        }
    }
    if edits.is_empty() {
        return None;
    }
    let mut out = display.to_owned();
    for (a, b, s) in edits.into_iter().rev() {
        out.replace_range(a..b, &s);
    }
    Some(out)
}

pub(super) fn normally_lower(word: &str) -> bool {
    let id = MODEL.id(word);
    id != 0 && MODEL.lex[id as usize].domain >= 2. && MODEL.lex[id as usize].normal == word
}
