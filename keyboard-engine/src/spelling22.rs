//! A word noisy channel. A pruned trie generates candidates from ordinary English
//! and the paired corpus. Character confusion costs and local left/right phrase
//! counts inform a fitted conditional ranker. The literal always competes.
#![allow(unexpected_cfgs)] // spelling22_training is enabled only by the standalone trainer.
use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    sync::LazyLock,
};

const MAX: usize = 28;
const FEATURES: usize = 24;
const CONTEXTS: &[u8] = include_bytes!("../model/spelling22/contexts.bin");
const COEFFICIENTS: &str = include_str!("../model/spelling22/ranker.txt");

struct Word {
    text: &'static str,
    display: &'static str,
    count: f32,
    english: f32,
}
#[derive(Default)]
struct Node {
    edges: Vec<(u8, usize)>,
    word: Option<u16>,
}
struct Lexicon {
    words: Vec<Word>,
    ids: HashMap<&'static str, u16>,
    observed: HashMap<&'static str, Vec<(u16, u16)>>,
    trie: Vec<Node>,
    substitute: [[f32; 28]; 28],
    swap: [[f32; 28]; 28],
    weights: Vec<f32>,
}
fn letter(c: u8) -> usize {
    if c == b'\'' {
        26
    } else {
        (c - b'a') as usize
    }
}
fn log_count(n: f32) -> f32 {
    n.ln_1p()
}
impl Lexicon {
    fn load() -> Self {
        let mut lex = Self {
            words: Vec::new(),
            ids: HashMap::new(),
            observed: HashMap::new(),
            trie: vec![Node::default()],
            substitute: [[10.5; 28]; 28],
            swap: [[7.5; 28]; 28],
            weights: COEFFICIENTS
                .split_whitespace()
                .map(|s| s.parse().unwrap())
                .collect(),
        };
        assert_eq!(lex.weights.len(), FEATURES);
        for row in include_str!("../model/spelling22/vocab.tsv").lines() {
            let mut cols = row.split('\t');
            let w = cols.next().unwrap();
            let id = lex.words.len() as u16;
            lex.ids.insert(w, id);
            lex.words.push(Word {
                text: w,
                display: cols.next().unwrap(),
                count: cols.next().unwrap().parse().unwrap(),
                english: cols.next().unwrap().parse().unwrap(),
            });
            if w.len() > MAX || !w.bytes().all(|c| c.is_ascii_lowercase() || c == b'\'') {
                continue;
            }
            let mut node = 0;
            for c in w.bytes() {
                let child = match lex.trie[node].edges.iter().find(|e| e.0 == c) {
                    Some(e) => e.1,
                    None => {
                        let child = lex.trie.len();
                        lex.trie.push(Node::default());
                        lex.trie[node].edges.push((c, child));
                        child
                    }
                };
                node = child;
            }
            lex.trie[node].word = Some(id);
        }
        for row in include_str!("../model/spelling22/observed.tsv").lines() {
            let mut cols = row.split('\t');
            let (w, id, count) = (
                cols.next().unwrap(),
                cols.next().unwrap().parse().unwrap(),
                cols.next().unwrap().parse().unwrap(),
            );
            lex.observed.entry(w).or_default().push((id, count));
        }
        for row in include_str!("../model/spelling22/edits.tsv").lines() {
            let mut cols = row.split('\t');
            let a = cols.next().unwrap().as_bytes();
            let b = cols.next().unwrap().as_bytes();
            let cost = cols.next().unwrap().parse().unwrap();
            let first = |s: &[u8]| s.first().map_or(27, |&c| letter(c));
            if a.len() == 2 {
                lex.swap[letter(a[0])][letter(a[1])] = cost;
            } else {
                lex.substitute[first(a)][first(b)] = cost;
            }
        }
        lex
    }
    fn nearby(
        &self,
        node: usize,
        previous: u8,
        input: &[u8],
        prev: &[u8; MAX + 1],
        prev2: &[u8; MAX + 1],
        limit: u8,
        out: &mut Vec<(u16, u8)>,
    ) {
        for &(c, child) in &self.trie[node].edges {
            let mut row = [0u8; MAX + 1];
            row[0] = prev[0] + 1;
            let mut lowest = row[0];
            for (j, &b) in input.iter().enumerate() {
                let mut d = (prev[j] + u8::from(c != b))
                    .min(prev[j + 1] + 1)
                    .min(row[j] + 1);
                if j > 0 && previous == b && c == input[j - 1] {
                    d = d.min(prev2[j - 1] + 1);
                }
                row[j + 1] = d;
                lowest = lowest.min(d);
            }
            if lowest > limit {
                continue;
            }
            let distance = row[input.len()];
            if distance <= limit {
                if let Some(id) = self.trie[child].word {
                    out.push((id, distance));
                }
            }
            self.nearby(child, c, input, &row, prev, limit, out);
        }
    }
    fn channel(&self, intended: &str, typed: &str) -> f32 {
        let (a, b) = (intended.as_bytes(), typed.as_bytes());
        let mut prev = [0.; MAX + 1];
        let mut older = prev;
        let mut row = prev;
        for (j, &y) in b.iter().enumerate() {
            prev[j + 1] = prev[j] + self.substitute[27][letter(y)];
        }
        for (i, &x) in a.iter().enumerate() {
            let lx = letter(x);
            let del = self.substitute[lx][27];
            row[0] = prev[0] + del;
            for (j, &y) in b.iter().enumerate() {
                let ly = letter(y);
                let mut v = (prev[j] + if x == y { 0. } else { self.substitute[lx][ly] })
                    .min(prev[j + 1] + del)
                    .min(row[j] + self.substitute[27][ly]);
                if i > 0 && j > 0 && a[i - 1] == y && b[j - 1] == x {
                    v = v.min(older[j - 1] + self.swap[letter(a[i - 1])][lx]);
                }
                row[j + 1] = v;
            }
            std::mem::swap(&mut older, &mut prev);
            std::mem::swap(&mut prev, &mut row);
        }
        prev[b.len()]
    }
    fn id(&self, w: &str) -> Option<u16> {
        self.ids.get(w).copied()
    }
    fn context(&self, ids: &[Option<u16>]) -> f32 {
        let mut code = 0u64;
        for &id in ids {
            let Some(i) = id else { return 0. };
            code = (code << 16) | (u64::from(i) + 1);
        }
        let mut lo = 0;
        let mut hi = CONTEXTS.len() / 10;
        while lo < hi {
            let i = (hi + lo) / 2;
            let row = &CONTEXTS[10 * i..10 * i + 10];
            match u64::from_le_bytes(row[..8].try_into().unwrap()).cmp(&code) {
                std::cmp::Ordering::Less => lo = i + 1,
                std::cmp::Ordering::Greater => hi = i,
                std::cmp::Ordering::Equal => return u16::from_le_bytes([row[8], row[9]]) as f32,
            }
        }
        0.
    }
}
static MODEL: LazyLock<Lexicon> = LazyLock::new(Lexicon::load);

// Punctuation between the cursor and a neighbor ends that context window.
fn context_words(s: &str, left: bool) -> Vec<String> {
    let boundary = |c: char| matches!(c, '.' | '?' | '!' | ';' | ':' | '\n');
    let segment = if left {
        s.rsplit(boundary).next()
    } else {
        s.split(boundary).next()
    }
    .unwrap_or("");
    let segment = segment.replace('’', "'").to_ascii_lowercase();
    let words = segment
        .split(|c: char| !c.is_ascii_lowercase() && c != '\'')
        .filter(|s| !s.is_empty());
    if left {
        words.rev().take(2).map(str::to_owned).collect()
    } else {
        words.take(2).map(str::to_owned).collect()
    }
}
struct Query<'a> {
    raw: &'a str,
    typed: String,
    known: Option<u16>,
    neighbors: [Option<u16>; 4], // nearest/further left, nearest/further right
    start: bool,
    title: bool,
    generic: bool,
}
impl<'a> Query<'a> {
    fn new(left: &str, raw: &'a str, right: &str, hide: bool, generic: bool) -> Option<Self> {
        let raw_ascii = raw.replace('’', "'");
        if !(2..=MAX).contains(&raw_ascii.len())
            || !raw_ascii
                .bytes()
                .all(|c| c.is_ascii_alphabetic() || c == b'\'')
        {
            return None;
        }
        let title = raw_ascii.as_bytes()[0].is_ascii_uppercase();
        if raw_ascii.as_bytes()[1..].iter().any(u8::is_ascii_uppercase) {
            return None;
        }
        let typed = raw_ascii.to_ascii_lowercase();
        let l = context_words(left, true);
        let r = context_words(right, false);
        let start = l.is_empty();
        let nearest = |ws: &[String], n: usize| ws.get(n).and_then(|w| MODEL.id(w));
        let sos = MODEL.id("^");
        let neighbors = [
            if start { sos } else { nearest(&l, 0) },
            if l.len() == 1 { sos } else { nearest(&l, 1) },
            nearest(&r, 0),
            nearest(&r, 1),
        ];
        let known = if hide { None } else { MODEL.id(&typed) };
        Some(Self {
            raw,
            typed,
            known,
            neighbors,
            start,
            title,
            generic,
        })
    }
    fn candidates(&self) -> Vec<Candidate> {
        let input = self.typed.as_bytes();
        let observations = if self.generic {
            &[][..]
        } else {
            MODEL
                .observed
                .get(self.typed.as_str())
                .map(Vec::as_slice)
                .unwrap_or(&[])
        };
        let mut found = Vec::new();
        if self.known.is_none() {
            let limit = if input.len() < 4 {
                1
            } else if input.len() < 7 {
                2
            } else {
                3
            };
            let root = std::array::from_fn(|j| j as u8);
            MODEL.nearby(0, 0, input, &root, &root, limit, &mut found);
        }
        // Observations also bring in natural confusions outside the trie radius.
        for &(id, _) in observations {
            if !found.iter().any(|&(j, _)| j == id) {
                found.push((id, 0));
            }
        }
        let mut rows = vec![self.describe(self.known, 0, 0, true)];
        for (id, d) in found {
            let w = &MODEL.words[id as usize];
            if w.text == self.typed
                || (self.title && !self.start && !w.display.as_bytes()[0].is_ascii_uppercase())
            {
                continue;
            }
            let n = observations.iter().find(|x| x.0 == id).map_or(0, |x| x.1);
            rows.push(self.describe(Some(id), d, n, false));
        }
        rows
    }
    fn describe(&self, id: Option<u16>, dist: u8, observed: u16, literal: bool) -> Candidate {
        let [l, ll, r, rr] = if self.generic {
            [None; 4]
        } else {
            self.neighbors
        };
        let word = id.map(|i| &MODEL.words[i as usize]);
        let (freq, english) = word.map_or((0., 0.), |w| (w.count, w.english));
        let count = |seq: &[Option<u16>]| MODEL.context(seq);
        let (lc, rc) = (count(&[l, id]), count(&[id, r]));
        let tri = count(&[l, id, r]);
        let side_tri = count(&[ll, l, id]).max(count(&[id, r, rr]));
        let count_features = [lc, rc, tri, side_tri].map(log_count);
        let cost = if literal {
            0.
        } else {
            MODEL.channel(word.unwrap().text, &self.typed)
        };
        let len = self.typed.len() as f32;
        let known = self.known.is_some();
        let b = |v| if v { 1. } else { 0. };
        let is_name = word.is_some_and(|w| {
            w.display.as_bytes()[0].is_ascii_uppercase()
                && w.display != "I"
                && !w.display.starts_with("I'")
        });
        // A missing-right context is an ordinary online word-boundary decision.
        let [left, right, middle, side] = count_features;
        let x = [
            b(literal),
            b(literal && known),
            b(literal && known && self.title),
            b(literal) * len.min(12.),
            b(literal && self.title),
            log_count(if self.generic { 0. } else { freq }),
            log_count(english),
            -cost,
            -cost / len.sqrt(),
            log_count(f32::from(observed)),
            b(observed > 0),
            left,
            right,
            middle,
            side,
            left.min(right),
            left.max(right),
            b(is_name && self.title),
            b(is_name && !self.title),
            b(literal && len <= 3.),
            b(literal && known && r.is_none()),
            b(literal && known && (lc > 0. || rc > 0.)),
            b(literal && known && tri > 0.),
            b(!literal && id.is_some()),
        ];
        Candidate {
            id,
            x,
            observed,
            dist,
            local: lc.max(rc),
            tri: tri.max(side_tri),
        }
    }
}
struct Candidate {
    id: Option<u16>,
    x: [f32; FEATURES],
    observed: u16,
    dist: u8,
    local: f32,
    tri: f32,
}
fn correction(left: &str, typed: &str, right: &str) -> Option<String> {
    let q = Query::new(left, typed, right, false, false)?;
    if q.known.is_some() && !MODEL.observed.contains_key(q.typed.as_str()) {
        return None;
    }
    if q.title
        && q.known
            .is_some_and(|i| MODEL.words[i as usize].display.as_bytes()[0].is_ascii_uppercase())
    {
        return None;
    }
    let rows = q.candidates();
    if rows.len() < 2 {
        return None;
    }
    let scores: Vec<f32> = rows
        .iter()
        .map(|row| row.x.iter().zip(&MODEL.weights).map(|(x, w)| x * w).sum())
        .collect();
    let (best, &score) = scores
        .iter()
        .enumerate()
        .max_by(|a, b| a.1.total_cmp(b.1))?;
    if best == 0 {
        return None;
    }
    let row = &rows[best];
    let known = q.known.is_some();
    if known
        && (row.observed < 2 || row.local < 2. || (rows[0].tri >= 2. && rows[0].tri >= row.tri))
    {
        return None;
    }
    if !known && q.typed.len() <= 3 && row.local < 2. && row.observed < 8 {
        return None;
    }
    let odds: f32 = scores
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != best)
        .map(|(_, s)| (s - score).exp())
        .sum();
    let confidence = 1. / (1. + odds);
    // A single dictionary word at edit distance one can be decisively ahead
    // even when its inflections contribute several distance-two rivals.
    let sole_neighbor = row.dist == 1 && rows.iter().skip(1).filter(|c| c.dist == 1).count() == 1;
    let minimum = if known {
        0.993
    } else if q.title && !q.start {
        0.99
    } else if q.typed.len() <= 3 {
        0.97
    } else if sole_neighbor && q.typed.len() >= 6 && !q.title {
        0.86
    } else {
        0.94
    };
    if confidence < minimum {
        return None;
    }
    let w = &MODEL.words[row.id? as usize];
    if row.dist >= 3 && row.local == 0. && row.observed == 0 {
        return None;
    }
    let mut display = w.display.to_owned();
    if q.title && q.start {
        display[..1].make_ascii_uppercase();
    }
    if q.raw.contains('’') {
        display = display.replace('\'', "’");
    }
    Some(display)
}

/// Ranked single-word replacement, preserving surface case. An empty right side
/// scores a delimiter commit; a later call can supply following context.
/// # Safety
/// Inputs must be NUL-terminated UTF-8, and out must have capacity writable bytes.
#[no_mangle]
pub unsafe extern "C" fn mb_spelling22_v1(
    left: *const c_char,
    typed: *const c_char,
    right: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if left.is_null() || typed.is_null() || right.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    unsafe {
        *out = 0;
    }
    let (Ok(l), Ok(t), Ok(r)) = (
        unsafe { CStr::from_ptr(left) }.to_str(),
        unsafe { CStr::from_ptr(typed) }.to_str(),
        unsafe { CStr::from_ptr(right) }.to_str(),
    ) else {
        return -1;
    };
    if l.len() > 2048 || r.len() > 2048 {
        return -1;
    }
    let Some(w) = correction(l, t, r) else {
        return 0;
    };
    if w.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(w.as_ptr(), out.cast(), w.len());
        *out.add(w.len()) = 0;
    }
    1
}
/// Whether the training or general English vocabulary contains this literal.
/// # Safety
/// Input must be a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn mb_spelling22_known_v1(raw: *const c_char) -> i32 {
    if raw.is_null() {
        return 0;
    }
    unsafe { CStr::from_ptr(raw) }
        .to_str()
        .ok()
        .is_some_and(|w| {
            MODEL
                .id(&w.to_ascii_lowercase().replace('’', "'"))
                .is_some()
        }) as i32
}

// Private training ABI compiled only by spelling22.py. The optimizer sees the
// exact candidate generator and feature definitions used on the device.
#[cfg(spelling22_training)]
#[no_mangle]
pub unsafe extern "C" fn mb22_features(
    left: *const c_char,
    raw: *const c_char,
    right: *const c_char,
    hide: bool,
    generic: bool,
    ids: *mut i32,
    values: *mut f32,
    capacity: usize,
) -> usize {
    let get = |s| unsafe { CStr::from_ptr(s) }.to_str().unwrap();
    let Some(q) = Query::new(get(left), get(raw), get(right), hide, generic) else {
        return 0;
    };
    let candidates = q.candidates();
    if candidates.len() > capacity {
        return 0;
    }
    for (i, c) in candidates.iter().enumerate() {
        unsafe {
            *ids.add(i) = c.id.map_or(-1, i32::from);
            std::ptr::copy_nonoverlapping(c.x.as_ptr(), values.add(i * FEATURES), FEATURES);
        }
    }
    candidates.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_prefers_attested_transposition_to_two_independent_substitutions() {
        assert_eq!(MODEL.channel("probably", "probably"), 0.0);
        let swap = MODEL.channel("probably", "probabyl");
        let independent = MODEL.substitute[letter(b'l')][letter(b'y')]
            + MODEL.substitute[letter(b'y')][letter(b'l')];
        assert!(swap > 0.0 && swap < independent);
    }

    #[test]
    fn generalizes_to_words_outside_paired_training() {
        // These words are present only in the ordinary English dictionary.
        let w = &MODEL.words[MODEL.id("accommodate").unwrap() as usize];
        assert_eq!(w.count, 0.0);
        assert!(!MODEL.observed.contains_key("accomodate"));
        assert_eq!(
            correction("We must ", "accomodate", " the dancers").as_deref(),
            Some("accommodate")
        );
        assert_eq!(
            correction("The local ", "enviroment", " changed").as_deref(),
            Some("environment")
        );
    }

    #[test]
    fn preserves_identifiers_and_mid_sentence_names() {
        for w in [
            "PDF", "BuildKit", "Sophia", "Paris", "MiXeD", "café", "bob42",
        ] {
            assert_eq!(correction("Please ask ", w, " tomorrow"), None, "{w}");
        }
    }
}
