//! Context votes for both meanings. A literal vote can veto another ranker.
//! Static packed features are fitted from distinct clean messages.
use std::{collections::HashMap, sync::LazyLock};

const DATA: &[u8] = include_bytes!("../model/evidence45/votes.bin");
static KEYS: LazyLock<Vec<&str>> = LazyLock::new(|| {
    include_str!("../model/evidence45/keys.txt")
        .lines()
        .collect()
});
struct OptionRow {
    word: &'static str,
    start: usize,
    ends: usize,
}
static ROWS: LazyLock<HashMap<&str, Vec<OptionRow>>> = LazyLock::new(|| {
    let mut r: HashMap<_, Vec<_>> = HashMap::new();
    for l in include_str!("../model/evidence45/headers.tsv").lines() {
        let mut f = l.split('\t');
        let word = f.next().unwrap();
        let target = f.next().unwrap();
        let start: usize = f.next().unwrap().parse().unwrap();
        let n: usize = f.next().unwrap().parse().unwrap();
        r.entry(word).or_default().push(OptionRow {
            word: target,
            start,
            ends: start + n,
        });
    }
    r
});
impl OptionRow {
    fn value(&self, key: usize) -> i32 {
        let read =
            |i: usize| u32::from_le_bytes(DATA[i * 5..i * 5 + 4].try_into().unwrap()) as usize;
        let (mut lo, mut hi) = (self.start, self.ends);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if read(mid) < key {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo == self.ends || read(lo) != key {
            0
        } else {
            DATA[lo * 5 + 4] as i8 as i32
        }
    }
}
fn features(left: &str, right: &str) -> Option<[Option<usize>; 7]> {
    let sep = |c: char| !(c.is_ascii_alphabetic() || c == '\'');
    let stop = ['.', '!', '?', ';', ':', '\n'];
    let l = left.rsplit(stop).next()?.to_ascii_lowercase();
    let r = right.split(stop).next()?.to_ascii_lowercase();
    let mut prev = l.split(sep).rev().filter(|x| !x.is_empty());
    let mut next = r.split(sep).filter(|x| !x.is_empty());
    let b = prev.next().unwrap_or("^");
    let a = prev.next().unwrap_or("^");
    let d = next.next()?;
    let e = next.next().unwrap_or("?");
    let cl = |w: &str| {
        super::cloze27::grammar_class(w)
            .map(|n| n.to_string())
            .unwrap_or_else(|| "?".into())
    };
    Some(
        [
            format!("1:{a}/{b}"),
            format!("2:{b}/{d}"),
            format!("3:{d}/{e}"),
            format!("4:{b}"),
            format!("5:{d}"),
            format!("6:{}/{d}", cl(b)),
            format!("7:{b}/{}", cl(d)),
        ]
        .map(|x| KEYS.binary_search(&x.as_str()).ok()),
    )
}
fn votes(row: &OptionRow, features: &[Option<usize>; 7], direction: i32) -> bool {
    let v = features.map(|x| direction * x.map_or(0, |id| row.value(id)));
    // A whole lexical window plus non-conflicting evidence from another
    // offset, or exceptionally strong overlapping contextual windows.
    v[..3].iter().any(|n| *n >= 2)
        && v.iter().all(|n| *n >= 0)
        && ((v[0] >= 2 && (v[2] >= 1 || v[4] >= 2 || v[5] >= 2))
            || (v[2] >= 2 && (v[0] >= 1 || v[3] >= 2 || v[6] >= 2))
            || (v[1] >= 2 && (v[0] >= 1 || v[2] >= 1 || v[3] >= 2 && v[4] >= 2)))
}
pub(super) fn protects(left: &str, w: &str, right: &str, proposed: &str) -> bool {
    let Some(row) = ROWS
        .get(w)
        .and_then(|v| v.iter().find(|x| x.word == proposed))
    else {
        return false;
    };
    features(left, right).is_some_and(|f| {
        let v = f.map(|x| x.map_or(0, |id| row.value(id)));
        // Protection can use only the literal's left-hand evidence when the
        // right neighbor is not yet complete. Abstention does not edit text.
        votes(row, &f, -1) || (v[0] <= -2 || v[1] <= -2) && v[..3].iter().all(|n| *n <= 0)
    })
}
pub(super) fn repair(left: &str, w: &str, right: &str) -> Option<String> {
    let options = ROWS.get(w)?;
    let f = features(left, right)?;
    let mut wins = options.iter().filter(|r| super::contrast40::allowed(w, r.word) && votes(r, &f, 1));
    let best = wins.next()?;
    wins.next().is_none().then(|| best.word.into())
}
