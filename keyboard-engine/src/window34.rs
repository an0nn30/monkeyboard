//! Only three context words within a four-token window are indexed. The model
//! compares their independent votes and never requests a stored sentence.
use std::{collections::HashMap, sync::LazyLock};
type Id = u16;
const OFFSETS: [[isize; 3]; 6] = [
    [-2, -1, 1],
    [-1, 1, 2],
    [-3, -2, -1],
    [1, 2, 3],
    [-2, 1, 2],
    [-2, -1, 2],
];
static VOCAB: LazyLock<Vec<(&str, &str)>> = LazyLock::new(|| {
    std::iter::once(("", ""))
        .chain(
            include_str!("../model/window34/vocab.tsv")
                .lines()
                .filter_map(|s| s.split_once('\t')),
        )
        .collect()
});
static IDS: LazyLock<HashMap<&str, Id>> = LazyLock::new(|| {
    VOCAB
        .iter()
        .enumerate()
        .map(|(i, w)| (w.0, i as Id))
        .collect()
});
const FILE: &[u8] = include_bytes!("../model/window34/contexts.bin");
fn read(i: usize) -> Id {
    u16::from_le_bytes([FILE[i], FILE[i + 1]])
}
fn lookup(p: usize, a: Id, b: Id, c: Id) -> Option<(Id, u8)> {
    let wanted = (p as u8, a, b, c);
    let (mut lo, mut hi) = (0, FILE.len() / 11);
    while lo < hi {
        let m = (lo + hi) / 2;
        let i = m * 11;
        let key = (FILE[i], read(i + 1), read(i + 3), read(i + 5));
        if key < wanted {
            lo = m + 1
        } else if wanted < key {
            hi = m
        } else {
            return Some((read(i + 7), FILE[i + 9]));
        }
    }
    None
}
pub(super) fn refine(raw: &str, input: &str) -> Option<String> {
    let mut terms = input.split(' ').map(str::to_string).collect::<Vec<_>>();
    if !(4..=12).contains(&terms.len()) {
        return None;
    }
    let lower = terms
        .iter()
        .map(|s| s.to_ascii_lowercase())
        .collect::<Vec<_>>();
    let ids = lower
        .iter()
        .map(|w| IDS.get(w.as_str()).copied().unwrap_or(0))
        .collect::<Vec<_>>();
    let original = raw
        .split(' ')
        .map(str::to_ascii_lowercase)
        .collect::<Vec<_>>();
    let aligned = original.len() == terms.len();
    let mut changed = false;
    for (i, (s, w)) in terms.iter_mut().zip(&lower).enumerate() {
        if w.len() < 2
            || w.len() > 23
            || !w.bytes().all(|b| b.is_ascii_alphanumeric() || b == 39)
            || s.bytes().all(|b| b.is_ascii_uppercase())
        {
            continue;
        }
        let mut votes = HashMap::<Id, (usize, usize)>::new();
        for (p, ofs) in OFFSETS.iter().enumerate() {
            let [a, b, c] = ofs.map(|j| {
                (i as isize + j)
                    .try_into()
                    .ok()
                    .and_then(|k: usize| ids.get(k).copied())
                    .unwrap_or(0)
            });
            if a == 0 || b == 0 || c == 0 {
                continue;
            }
            if let Some((target, n)) = lookup(p, a, b, c) {
                let e = votes.entry(target).or_default();
                e.0 += 1;
                e.1 += n.min(12) as usize;
            }
        }
        if votes.contains_key(&ids[i]) {
            continue;
        }
        let mut order = votes.into_iter().collect::<Vec<_>>();
        order.sort_by_key(|&(id, (v, n))| (std::cmp::Reverse((v, n)), id));
        let Some(&(id, (agree, score))) = order.first() else {
            continue;
        };
        let (winner, display) = VOCAB[id as usize];
        let known = ids[i] != 0 || super::WORDS.contains_key(w.as_str());
        let typed = if aligned { original[i].as_str() } else { w };
        let observed = super::denoise22::attestation(typed, winner);
        let tested = observed >= 2. || typed != w && !super::WORDS.contains_key(typed);
        if agree < if known && !tested { 3 } else { 1 }
            || score
                < if known && !tested {
                    14
                } else if observed >= 2. {
                    2
                } else {
                    4
                }
            || order.get(1).is_some_and(|(_, x)| x.0 + 1 >= agree)
        {
            continue;
        }
        let d = super::wordnet22::distance(typed, winner);
        if d == 0
            || (d > if known && !tested {
                1
            } else {
                (winner.len() / 3 + 1).min(4)
            } && observed < 2.)
        {
            continue;
        }
        if s.bytes().skip(1).any(|b| b.is_ascii_uppercase()) && agree < 2 {
            continue;
        }
        if s.starts_with(char::is_uppercase) && i > 0 && (known || agree < 2) {
            continue;
        }
        let mut target = display.to_string();
        if i == 0 && s.starts_with(char::is_uppercase) {
            target[..1].make_ascii_uppercase()
        }
        *s = target;
        changed = true;
    }
    changed.then(|| terms.join(" "))
}
