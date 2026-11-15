//! Conversational nonword decoder. The literal competes with all dictionary
//! rivals at one Damerau edit, including common SMS words and short fragments.
use std::{collections::HashMap, sync::LazyLock};
const DATA: &[u8] = include_bytes!("../model/textspell30/contexts.bin");
const F: usize = 27;
struct Word {
    text: &'static str,
    c: f32,
    e: f32,
    s: f32,
    candidate: bool,
}
struct Edit {
    single: [[f32; 28]; 28],
    swap: [[f32; 28]; 28],
}
fn ix(b: u8) -> usize {
    if b == b'\'' {
        26
    } else {
        (b - b'a') as usize
    }
}
struct Model {
    words: Vec<Word>,
    ids: HashMap<&'static str, u16>,
    attested: HashMap<&'static str, Vec<(u16, u16)>>,
    edit: Edit,
    weights: [f32; F],
    threshold: [[f32; 2]; 2],
}
static MODEL: LazyLock<Model> = LazyLock::new(|| {
    let mut words = Vec::new();
    let mut ids = HashMap::new();
    for (i, row) in include_str!("../model/textspell30/vocab.tsv")
        .lines()
        .enumerate()
    {
        let mut f = row.split('\t');
        let text = f.next().unwrap();
        let c = f.next().unwrap().parse::<f32>().unwrap().ln_1p();
        let e = f.next().unwrap().parse::<f32>().unwrap().ln_1p();
        let s = f.next().unwrap().parse::<f32>().unwrap().ln_1p();
        let candidate = f.next().unwrap() == "1";
        ids.insert(text, i as u16);
        words.push(Word {
            text,
            c,
            e,
            s,
            candidate,
        });
    }
    let mut edit = Edit {
        single: [[10.5; 28]; 28],
        swap: [[7.5; 28]; 28],
    };
    for row in include_str!("../model/textspell30/edits.tsv").lines() {
        let mut f = row.split('\t');
        let a = f.next().unwrap().as_bytes();
        let b = f.next().unwrap().as_bytes();
        let c = f.next().unwrap().parse().unwrap();
        if a.len() == 2 {
            edit.swap[ix(a[0])][ix(a[1])] = c;
        } else {
            let x = a.first().map_or(27, |v| ix(*v));
            let y = b.first().map_or(27, |v| ix(*v));
            edit.single[x][y] = c;
        }
    }
    let mut attested: HashMap<_, Vec<_>> = HashMap::new();
    for row in include_str!("../model/textspell30/observed.tsv").lines() {
        let mut f = row.split('\t');
        let w = f.next().unwrap();
        attested.entry(w).or_default().push((
            f.next().unwrap().parse().unwrap(),
            f.next().unwrap().parse().unwrap(),
        ));
    }
    let weights = include_str!("../model/textspell30/rank.txt")
        .split_whitespace()
        .map(|s| s.parse().unwrap())
        .collect::<Vec<_>>()
        .try_into()
        .unwrap();
    let threshold = [
        include_str!("../model/textspell30/short.txt"),
        include_str!("../model/textspell30/long.txt"),
    ]
    .map(|s| {
        s.split_whitespace()
            .map(|s| s.parse().unwrap())
            .collect::<Vec<_>>()
            .try_into()
            .unwrap()
    });
    Model {
        words,
        ids,
        attested,
        edit,
        weights,
        threshold,
    }
});
fn count(a: u16, b: u16, c: u16) -> f32 {
    let code = (u64::from(a) << 32) | (u64::from(b) << 16) | u64::from(c);
    let (mut lo, mut hi) = (0, DATA.len() / 10);
    while lo < hi {
        let mid = (lo + hi) / 2;
        let r = &DATA[10 * mid..10 * mid + 10];
        match u64::from_le_bytes(r[..8].try_into().unwrap()).cmp(&code) {
            std::cmp::Ordering::Greater => hi = mid,
            std::cmp::Ordering::Less => lo = mid + 1,
            std::cmp::Ordering::Equal => {
                return f32::from(u16::from_le_bytes([r[8], r[9]])).ln_1p()
            }
        }
    }
    0.
}
fn rivals(typed: &str) -> HashMap<u16, f32> {
    let bytes = typed.as_bytes();
    let mut scores = HashMap::new();
    let mut buf = Vec::with_capacity(bytes.len() + 1);
    let e = &MODEL.edit;
    let mut offer = |b: &[u8], cost: f32| {
        let w = std::str::from_utf8(b).unwrap();
        if let Some(&i) = MODEL.ids.get(w) {
            if MODEL.words[i as usize].candidate {
                let v = scores.entry(i).or_insert(f32::INFINITY);
                *v = v.min(cost);
            }
        }
    };
    const LETTERS: &[u8] = b"abcdefghijklmnopqrstuvwxyz'";
    for (i, &c) in bytes.iter().enumerate() {
        buf.clear();
        buf.extend_from_slice(&bytes[..i]);
        buf.extend_from_slice(&bytes[i + 1..]);
        offer(&buf, e.single[27][ix(c)]);
        buf.clear();
        buf.extend_from_slice(bytes);
        for &other in LETTERS {
            if other != c {
                buf[i] = other;
                offer(&buf, e.single[ix(other)][ix(c)]);
            }
        }
        if i > 0 && c != bytes[i - 1] {
            buf.copy_from_slice(bytes);
            buf.swap(i - 1, i);
            offer(&buf, e.swap[ix(c)][ix(bytes[i - 1])]);
        }
    }
    for i in 0..=bytes.len() {
        buf.clear();
        buf.extend_from_slice(&bytes[..i]);
        buf.push(b'a');
        buf.extend_from_slice(&bytes[i..]);
        for &c in LETTERS {
            buf[i] = c;
            offer(&buf, e.single[ix(c)][27]);
        }
    }
    scores
}
fn dot(x: [f32; F]) -> f32 {
    x.iter().zip(&MODEL.weights).map(|(a, b)| a * b).sum()
}
/// Only unknown spellings are eligible. Text keys exclude digits, non-ASCII
/// letters and code-like casing; known casual words automatically abstain.
pub(super) fn repair(left: &str, typed: &str, right: &str) -> Option<String> {
    let w = typed.replace('’', "'");
    let bytes = w.as_bytes();
    if !(2..=22).contains(&bytes.len())
        || !bytes.iter().all(|b| b.is_ascii_alphabetic() || *b == b'\'')
        || bytes[1..].iter().any(u8::is_ascii_uppercase)
    {
        return None;
    }
    let title = bytes[0].is_ascii_uppercase();
    let w = w.to_ascii_lowercase();
    if MODEL.ids.contains_key(w.as_str()) {
        return None;
    }
    let stop = |c| matches!(c, '.' | '!' | '?' | ';' | ':' | '\n');
    let l = left
        .rsplit(stop)
        .next()?
        .replace('’', "'")
        .to_ascii_lowercase();
    let r = right
        .split(stop)
        .next()?
        .replace('’', "'")
        .to_ascii_lowercase();
    let sep = |c: char| !c.is_ascii_lowercase() && c != '\'';
    let mut ls = l.split(sep).filter(|s| !s.is_empty()).rev();
    let mut rs = r.split(sep).filter(|s| !s.is_empty());
    let sos = MODEL.ids["^"] + 1;
    let lex = |s: &str| MODEL.ids.get(s).map_or(0, |&i| i + 1);
    let b = ls.next().map_or(sos, lex);
    let a = ls.next().map_or(sos, lex);
    let d = rs.next().map_or(0, lex);
    let e = rs.next().map_or(0, lex);
    if title && b != sos {
        return None;
    }
    let len = w.len();
    let short = len <= 3;
    let mut literal = [0.; F];
    literal[0] = 1.;
    literal[1] = len.min(12) as f32;
    literal[2] = u8::from(short) as f32;
    literal[3] = u8::from(len == 2) as f32;
    literal[21] = u8::from(b == sos) as f32;
    literal[22] = u8::from(d == 0) as f32;
    literal[23] = u8::from(
        len >= 4
            && w.as_bytes()
                .windows(3)
                .any(|p| p[0] == p[1] && p[1] == p[2]),
    ) as f32;
    let base = dot(literal);
    let (mut top, mut runner, mut best) = (base, f32::NEG_INFINITY, None);
    let obs = MODEL
        .attested
        .get(w.as_str())
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let n = len as f32;
    for (id, cost) in rivals(&w) {
        let v = &MODEL.words[id as usize];
        let c = id + 1;
        let (lc, rc, tri, lp, rp) = (
            count(0, b, c),
            count(0, c, d),
            count(b, c, d),
            count(a, b, c),
            count(c, d, e),
        );
        let k = obs.iter().find(|(i, _)| *i == id).map_or(0, |v| v.1);
        let si = u8::from(short) as f32;
        let score = dot([
            0.,
            0.,
            0.,
            0.,
            v.c,
            v.e,
            v.s,
            -cost,
            -cost / n.sqrt(),
            f32::from(k).ln_1p(),
            u8::from(k > 0) as f32,
            lc,
            rc,
            tri,
            lp,
            rp,
            lc.min(rc),
            lc.max(rc),
            tri.max(lp).max(rp),
            si * lc,
            si * rc,
            0.,
            0.,
            0.,
            u8::from(v.text.len() > len) as f32,
            u8::from(v.text.len() < len) as f32,
            u8::from(v.text.len() > 1 && v.text.bytes().all(|b| b == w.as_bytes()[0])) as f32,
        ]);
        if score > top {
            runner = top;
            top = score;
            best = Some(id);
        } else {
            runner = runner.max(score);
        }
    }
    let [margin, gap] = MODEL.threshold[usize::from(!short)];
    let id = best?;
    if top - base < margin || top - runner < gap {
        return None;
    }
    let mut result = MODEL.words[id as usize].text.to_owned();
    if title || result == "i" || result.starts_with("i'") {
        result[..1].make_ascii_uppercase();
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keeps_observed_casual_spellings() {
        for w in ["lol", "lmao", "txt", "ur", "gonna"] {
            assert!(MODEL.ids.contains_key(w));
            assert_eq!(repair("please", w, "later"), None);
        }
    }
    #[test]
    fn handles_contextual_one_edit_nonword_and_preserves_mixed_case() {
        assert_eq!(repair("you ", "wkll", " need").as_deref(), Some("will"));
        assert_eq!(repair("you ", "WKll", " need"), None);
    }
}

#[path = "residual53.rs"]
pub(crate) mod residual53;
