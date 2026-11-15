//! Local frames that separate the candidate from the literal word. The trainer
//! admits a direction only after checking a separate clean calibration fold.
use std::{
    collections::HashMap,
    ffi::{c_char, CStr},
    sync::LazyLock,
};
type Frames = HashMap<&'static str, i16>;
type Directions = HashMap<&'static str, Vec<(&'static str, i16, Frames)>>;
static TABLE: LazyLock<Directions> = LazyLock::new(|| {
    let mut table: Directions = HashMap::new();
    for line in include_str!("../model/frames53/policy.tsv").lines() {
        let mut f = line.split('\t');
        let (x, y, t, k, v) = (
            f.next().unwrap(),
            f.next().unwrap(),
            f.next().unwrap(),
            f.next().unwrap(),
            f.next().unwrap(),
        );
        let group = table.entry(x).or_default();
        if group.last().map(|a| a.0) != Some(y) {
            group.push((y, t.parse().unwrap(), HashMap::new()))
        }
        group.last_mut().unwrap().2.insert(k, v.parse().unwrap());
    }
    table
});
fn resolve(left: &str, typed: &str, right: &str) -> Option<String> {
    if right.is_empty() || typed.len() > 12 || !typed.bytes().all(|b| b.is_ascii_lowercase()) {
        return None;
    }
    let options = TABLE.get(typed)?;
    let sep = |c: char| !c.is_ascii_alphabetic() && c != '\'';
    let stop = ['.', '!', '?', ';', ':', '\n'];
    let l = left.rsplit(stop).next()?.to_ascii_lowercase();
    let r = right.split(stop).next()?.to_ascii_lowercase();
    let mut prev = l.split(sep).filter(|s| !s.is_empty()).rev();
    let mut after = r.split(sep).filter(|s| !s.is_empty());
    let b = prev.next().unwrap_or("^");
    let a = prev.next().unwrap_or("^");
    let d = after.next()?;
    let e = after.next().unwrap_or("?");
    let cl = |w| super::cloze27::grammar_class(w).map_or_else(|| "?".into(), |n| n.to_string());
    let (bc, dc) = (cl(b), cl(d));
    let keys = [
        format!("0:{a}/{b}"),
        format!("1:{b}/{d}"),
        format!("2:{d}/{e}"),
        format!("3:{bc}/{d}"),
        format!("4:{b}/{dc}"),
        format!("5:{a}/{bc}/{dc}"),
        format!("6:{bc}/{dc}/{e}"),
        format!("7:{b}"),
        format!("8:{d}"),
        format!("9:{bc}/{dc}"),
        format!("A:{}/{bc}", cl(a)),
        format!("B:{dc}/{}", cl(e)),
    ];
    let mut win = None;
    for (word, threshold, weights) in options {
        let mut v = keys
            .each_ref()
            .map(|k| weights.get(k.as_str()).copied().unwrap_or(0));
        let m = (*v[..3].iter().max()?).max(v[7].max(v[10]).min(v[8].max(v[11])));
        if m < 3
            || *v[..3].iter().min()? < -1
            || *v.iter().min()? < -4
            || v.iter().filter(|x| **x >= 2).count() < 3
            || !v[1..7]
                .iter()
                .chain([&v[8], &v[9], &v[11]])
                .any(|x| *x >= 2)
        {
            continue;
        }
        v.sort_unstable();
        if m + v[v.len() - 3..].iter().sum::<i16>() >= *threshold {
            if win.is_some() {
                return None;
            }
            win = Some(word.to_string());
        }
    }
    win
}
#[no_mangle]
pub unsafe extern "C" fn mb_context53_v1(
    l: *const c_char,
    t: *const c_char,
    r: *const c_char,
    o: *mut c_char,
    n: usize,
) -> i32 {
    if l.is_null() || t.is_null() || r.is_null() || o.is_null() || n == 0 {
        return -1;
    }
    let read = |p| CStr::from_ptr(p).to_str();
    let (Ok(l), Ok(t), Ok(r)) = (read(l), read(t), read(r)) else {
        return -1;
    };
    let Some(s) = resolve(l, t, r) else { return 0 };
    if n <= s.len() {
        return -1;
    }
    std::ptr::copy_nonoverlapping(s.as_ptr(), o.cast(), s.len());
    *o.add(s.len()) = 0;
    1
}
