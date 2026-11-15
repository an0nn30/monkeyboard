//! Short-word conditional ranker combining lexical and learned grammar-class
//! collocations with a noisy-channel prior. Always compare the typed literal.
use std::{collections::HashMap, sync::LazyLock};
const DATA: &[u8] = include_bytes!("../model/cloze27/counts.bin");
const DIM: usize = 21;
struct Target {
    word: &'static str,
    lex: u16,
    freq: f32,
    rivals: Vec<(usize, u32)>,
}
struct Model {
    vocab: HashMap<&'static str, u16>,
    classes: Vec<u16>,
    words: Vec<Target>,
    ids: HashMap<&'static str, usize>,
    w: [f32; DIM],
    margin: f32,
    gap: f32,
}
static MODEL: LazyLock<Model> = LazyLock::new(|| {
    let mut vocab = HashMap::new();
    let mut classes = Vec::new();
    for (i, s) in include_str!("../model/cloze27/vocab.tsv")
        .lines()
        .enumerate()
    {
        let (word, c) = s.split_once('\t').unwrap();
        vocab.insert(word, i as u16);
        classes.push(c.parse().unwrap());
    }
    let mut ids = HashMap::new();
    let mut words = Vec::new();
    for (i, s) in include_str!("../model/cloze27/targets.tsv")
        .lines()
        .enumerate()
    {
        let mut f = s.split('\t');
        let word = f.next().unwrap();
        let lex = f.next().unwrap().parse().unwrap();
        let freq = f.next().unwrap().parse().unwrap();
        let rivals = f
            .next()
            .unwrap()
            .split(',')
            .map(|r| {
                let (id, n) = r.split_once(':').unwrap();
                (id.parse().unwrap(), n.parse().unwrap())
            })
            .collect();
        ids.insert(word, i);
        words.push(Target {
            word,
            lex,
            freq,
            rivals,
        });
    }
    let w = include_str!("../model/cloze27/rank.txt")
        .split_whitespace()
        .map(|s| s.parse().unwrap())
        .collect::<Vec<_>>()
        .try_into()
        .unwrap();
    let mut policy = include_str!("../model/cloze27/policy.txt")
        .split_whitespace()
        .map(|s| s.parse::<f32>().unwrap());
    Model {
        vocab,
        classes,
        words,
        ids,
        w,
        margin: policy.next().unwrap(),
        gap: policy.next().unwrap(),
    }
});
fn count(kind: u16, a: u16, b: u16, c: u16) -> f32 {
    let key = (u64::from(kind) << 48) | (u64::from(a) << 32) | (u64::from(b) << 16) | u64::from(c);
    let blocks = u32::from_le_bytes(DATA[..4].try_into().unwrap()) as usize;
    let entry = |i: usize| &DATA[4 + 12 * i..4 + 12 * (i + 1)];
    let header = |i: usize| u64::from_le_bytes(entry(i)[..8].try_into().unwrap());
    let offset = |i: usize| u32::from_le_bytes(entry(i)[8..].try_into().unwrap()) as usize;
    let (mut lo, mut hi) = (0, blocks);
    while lo < hi {
        let m = (lo + hi) / 2;
        if header(m) <= key {
            lo = m + 1;
        } else {
            hi = m;
        }
    }
    if lo == 0 {
        return 0.;
    }
    let i = lo - 1;
    let base = 4 + 12 * blocks;
    let end = if lo == blocks {
        DATA.len()
    } else {
        base + offset(lo)
    };
    let mut buf = &DATA[base + offset(i)..end];
    let mut value = header(i);
    fn varint(buf: &mut &[u8]) -> u64 {
        let (mut result, mut shift) = (0, 0);
        loop {
            let byte = buf[0];
            *buf = &buf[1..];
            result |= u64::from(byte & 127) << shift;
            if byte & 128 == 0 {
                return result;
            }
            shift += 7;
        }
    }
    while !buf.is_empty() {
        value += varint(&mut buf);
        let n = varint(&mut buf);
        if value == key {
            return (n as f32).ln_1p();
        }
        if value > key {
            break;
        }
    }
    0.
}
pub(super) fn grammar_class(word: &str) -> Option<u16> {
    MODEL.vocab.get(word).map(|&id| MODEL.classes[id as usize])
}

struct Context {
    a: u16,
    b: u16,
    d: u16,
    e: u16,
    ac: u16,
    bc: u16,
    dc: u16,
    ec: u16,
}
impl Context {
    fn score(&self, t: &Target, observed: u32, literal: bool, len: usize) -> f32 {
        let c = t.lex;
        let (a, b, d, e) = (self.a, self.b, self.d, self.e);
        let (ac, bc, dc, ec) = (self.ac, self.bc, self.dc, self.ec);
        let lc = count(0, b, c, 0);
        let rc = count(0, c, d, 0);
        let mid = count(1, b, c, d);
        let left = count(1, a, b, c);
        let right = count(1, c, d, e);
        let center_class = count(2, bc, c, dc);
        let left_class = count(3, b, c, dc);
        let right_class = count(4, bc, c, d);
        let two_left_classes = count(5, ac, bc, c);
        let two_right_classes = count(6, c, dc, ec);
        let lit = if literal { 1. } else { 0. };
        let prior = (observed as f32).ln_1p();
        let x = [
            lit,
            t.freq,
            prior,
            prior.min(1.),
            lc,
            rc,
            mid,
            left,
            right,
            center_class,
            left_class,
            right_class,
            two_left_classes,
            two_right_classes,
            lc.min(rc),
            mid.max(left).max(right),
            left_class.min(right_class),
            lc.min(rc) * lit,
            t.freq * lit,
            if len <= 3 { lit } else { 0. },
            if len >= 5 { lit } else { 0. },
        ];
        x.iter().zip(MODEL.w.iter()).map(|(a, b)| a * b).sum()
    }
}
/// Supply original text and the available following words in this sentence.
pub(super) fn repair(left: &str, word: &str, right: &str) -> Option<String> {
    if !(2..=5).contains(&word.len()) || !word.bytes().all(|c| c.is_ascii_lowercase()) {
        return None;
    }
    let id = *MODEL.ids.get(word)?;
    let literal = &MODEL.words[id];
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
    let lex = |s: &str| MODEL.vocab.get(s).copied().unwrap_or(0);
    let b = ls.next().map_or(1, lex);
    let a = ls.next().map_or(1, lex);
    let d = lex(rs.next()?);
    let e = rs.next().map_or(2, lex);
    if d == 0 && b == 0 {
        return None;
    }
    let cl = |i: u16| MODEL.classes[i as usize];
    let ctx = Context {
        a,
        b,
        d,
        e,
        ac: cl(a),
        bc: cl(b),
        dc: cl(d),
        ec: cl(e),
    };
    let base = ctx.score(literal, 0, true, word.len());
    let (mut best, mut runner, mut selected) = (base, f32::NEG_INFINITY, id);
    for &(j, n) in &literal.rivals {
        let sc = ctx.score(&MODEL.words[j], n, false, word.len());
        if sc > best {
            runner = best;
            best = sc;
            selected = j;
        } else {
            runner = runner.max(sc);
        }
    }
    (selected != id && best - base >= MODEL.margin && best - runner >= MODEL.gap)
        .then(|| MODEL.words[selected].word.to_owned())
}
