//! Noisy-channel decoder: score a literal and all common one-edit competitors
//! with learned character confusions and interpolated word n-grams. No word-pair rules.
use super::{c_char, CStr, HashMap, LazyLock, WORDS};

static EDIT: LazyLock<HashMap<&str, f64>> = LazyLock::new(|| {
    include_str!("../model/short-channel.tsv")
        .lines()
        .filter_map(|s| {
            let (a, b) = s.split_once('\t')?;
            Some((a, b.parse().ok()?))
        })
        .collect()
});
static OBSERVED: LazyLock<HashMap<&str, f64>> = LazyLock::new(|| {
    include_str!("../model/short-observations.tsv")
        .lines()
        .filter_map(|s| {
            let (a, b) = s.split_once('\t')?;
            Some((a, b.parse().ok()?))
        })
        .collect()
});
static LITERALS: LazyLock<HashMap<&str, (u32, u32)>> = LazyLock::new(|| {
    include_str!("../model/short-literals.tsv")
        .lines()
        .filter_map(|s| {
            let mut f = s.split('\t');
            Some((
                f.next()?,
                (f.next()?.parse().ok()?, f.next()?.parse().ok()?),
            ))
        })
        .collect()
});
static PHRASES: LazyLock<Vec<(&str, u32)>> = LazyLock::new(|| {
    include_str!("../model/short-phrases.tsv")
        .lines()
        .filter_map(|s| {
            let (a, b) = s.split_once('\t')?;
            Some((a, b.parse().ok()?))
        })
        .collect()
});
fn n(s: &str) -> f64 {
    PHRASES
        .binary_search_by_key(&s, |v| v.0)
        .map_or(0., |i| PHRASES[i].1 as f64)
}

fn operation(x: &[u8], y: &[u8]) -> Option<[u8; 2]> {
    if x == y {
        return None;
    }
    if x.len() == y.len() {
        let mut d = x
            .iter()
            .zip(y)
            .enumerate()
            .filter(|(_, (a, b))| a != b)
            .map(|(i, _)| i);
        let i = d.next()?;
        return match d.next() {
            None => Some([y[i], x[i]]),
            Some(j) if j == i + 1 && d.next().is_none() && x[i] == y[j] && x[j] == y[i] => {
                Some([b'~', y[i]])
            }
            _ => None,
        };
    }
    let (long, short, insert) = if x.len() == y.len() + 1 {
        (x, y, true)
    } else if y.len() == x.len() + 1 {
        (y, x, false)
    } else {
        return None;
    };
    let i = long
        .iter()
        .zip(short)
        .position(|(a, b)| a != b)
        .unwrap_or(short.len());
    (long[i + 1..] == short[i..]).then(|| {
        if insert {
            [b'+', long[i]]
        } else {
            [long[i], b'-']
        }
    })
}

type Candidate = (&'static str, f64);
// Generate the edit neighbourhood once. The model file contains character
// operations; observed word-pair counts provide a soft prior at ranking time.
static INDEX: LazyLock<HashMap<String, Vec<Candidate>>> = LazyLock::new(|| {
    let mut map: HashMap<String, Vec<Candidate>> = HashMap::new();
    for (&dest, &freq) in WORDS.iter() {
        let y = dest.as_bytes();
        if !(1..=4).contains(&y.len()) || !y.iter().all(u8::is_ascii_lowercase) || freq < 5 {
            continue;
        }
        let mut offer = |x: Vec<u8>| {
            if !(2..=3).contains(&x.len()) {
                return;
            }
            let Some(op) = operation(&x, y) else { return };
            let rate = EDIT
                .get(std::str::from_utf8(&op).unwrap())
                .copied()
                .unwrap_or(0.);
            if rate < 2. {
                return;
            }
            let cs = map.entry(String::from_utf8(x).unwrap()).or_default();
            if !cs.iter().any(|v| v.0 == dest) {
                cs.push((dest, rate));
            }
        };
        for i in 0..y.len() {
            let mut x = y.to_vec();
            x.remove(i);
            offer(x);
            for c in b'a'..=b'z' {
                let mut x = y.to_vec();
                x[i] = c;
                offer(x);
            }
            if i > 0 {
                let mut x = y.to_vec();
                x.swap(i - 1, i);
                offer(x);
            }
        }
        for i in 0..=y.len() {
            for c in b'a'..=b'z' {
                let mut x = y.to_vec();
                x.insert(i, c);
                offer(x);
            }
        }
    }
    map
});
fn risk(w: &str) -> bool {
    let (kept, wrong) = LITERALS.get(w).copied().unwrap_or_default();
    (wrong >= 1 || (kept < 4 && !WORDS.contains_key(w))) && INDEX.contains_key(w)
}
fn prob(a: &str, b: &str, c: &str) -> f64 {
    let unig = (n(c) + 0.4) / 1_000_000.;
    let bi = n(&format!("{b} {c}"));
    let p = (bi + 6. * unig) / (n(b).max(bi) + 6.);
    if a.is_empty() {
        return p;
    }
    let tri = n(&format!("{a} {b} {c}"));
    (tri + 6. * p) / (n(&format!("{a} {b}")).max(tri) + 6.)
}
fn score(leading: &str, typed: &str, following: &str) -> Option<&'static str> {
    if !risk(typed) {
        return None;
    }
    let left = leading.to_ascii_lowercase();
    let mut l = left
        .rsplit(['.', '!', '?', ';', ':', '\n'])
        .next()?
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|s| !s.is_empty())
        .rev();
    let b = l.next().unwrap_or("^");
    let a = l.next().unwrap_or("");
    let right = following.to_ascii_lowercase();
    let mut r = right
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|s| !s.is_empty());
    let c = r.next();
    let d = r.next();
    if let Some(best) = legacy_score(leading, typed, following) {
        return Some(best);
    }
    // A repeated local frame in the new training corpus can resolve a real-word
    // slip even when the next word is a name outside the decoder vocabulary.
    // Compare all same-length one-edit rivals; require both a literal margin
    // and a runner-up margin. The transformer independently checks the winner.
    if let (Some(right), Some(pool)) = (c, INDEX.get(typed)) {
        if WORDS.contains_key(typed) {
            let frame = |w: &str| {
                use super::context21::count;
                let mid = count([b, w, right]);
                let lp = count([a, b, w]);
                let rp = d.map_or(0, |next| count([w, right, next]));
                let left = count([b, w]);
                let after = count([w, right]);
                let f = |n: u32| f64::from(n).ln_1p();
                (
                    f(mid) * 1.35 + f(lp) * 0.8 + f(rp) * 0.8 + f(left) * 0.65 + f(after) * 0.65,
                    mid,
                    lp,
                    rp,
                    left,
                    after,
                )
            };
            let orig = frame(typed);
            if orig.1 >= 3 || orig.2 >= 3 || orig.3 >= 3 {
                return None;
            }
            let mut best = ("", f64::NEG_INFINITY);
            let mut runner = f64::NEG_INFINITY;
            for &(w, _) in pool {
                if w.len() != typed.len() {
                    continue;
                }
                let ev = frame(w);
                let local = ev.1 >= 4
                    || (ev.2 >= 4 && ev.4 >= 10)
                    || (ev.3 >= 4 && ev.5 >= 10)
                    || (ev.4 >= 15 && ev.5 >= 15 && ev.1 >= 2);
                let v = ev.0;
                if v > best.1 {
                    runner = best.1;
                    best = (if local { w } else { "" }, v)
                } else {
                    runner = runner.max(v)
                }
            }
            if !best.0.is_empty() && best.1 - orig.0 > 5.5 && best.1 - runner > 2.0 {
                return Some(best.0);
            }
        }
    }
    None
}

fn legacy_score(leading: &str, typed: &str, following: &str) -> Option<&'static str> {
    if !risk(typed) {
        return None;
    }
    let left = leading.to_ascii_lowercase();
    let mut l = left
        .rsplit(['.', '!', '?', ';', ':', '\n'])
        .next()?
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|s| !s.is_empty())
        .rev();
    let b = l.next().unwrap_or("^");
    let a = l.next().unwrap_or("");
    let right = following.to_ascii_lowercase();
    let mut r = right
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|s| !s.is_empty());
    let c = r.next();
    let d = r.next();
    let lm = |w: &str| {
        let mut p = prob(a, b, w).ln();
        if let Some(c) = c {
            p += prob(b, w, c).ln();
            if let Some(d) = d {
                p += prob(w, c, d).ln();
            }
        }
        p
    };
    let (kept, errors) = LITERALS.get(typed).copied().unwrap_or_default();
    let known = n(typed) > 0. || WORDS.contains_key(typed);
    let literal = lm(typed);
    // Unknown proxy spellings need positive local evidence: a low <unk>
    // likelihood alone is never a reason to overwrite a name or technical term.
    let mut best = ("", f64::NEG_INFINITY);
    let mut runner = f64::NEG_INFINITY;
    for &(w, edit) in INDEX.get(typed)? {
        let votes = OBSERVED
            .get(format!("{typed}:{w}").as_str())
            .copied()
            .unwrap_or(0.);
        let val = lm(w) + 0.38 * ((edit + 1.) / 250.).ln() + (1. + votes).ln() * 0.8;
        if val > best.1 {
            runner = best.1;
            best = (w, val);
        } else {
            runner = runner.max(val);
        }
    }
    let w = best.0;
    let left_hits = n(&format!("{b} {w}"));
    let right_hits = c.map_or(0., |c| n(&format!("{w} {c}")));
    let phrase = c
        .map_or(0., |c| n(&format!("{b} {w} {c}")))
        .max(n(&format!("{a} {b} {w}")));
    let right_phrase = match (c, d) {
        (Some(c), Some(d)) => n(&format!("{w} {c} {d}")),
        _ => 0.,
    };
    let seen = (errors as f64 + 1.) / (kept as f64 + errors as f64 + 12.);
    let threshold = if known {
        4.2 + (-seen.ln()).min(6.) * 0.35
    } else {
        3.3
    };
    let votes = OBSERVED
        .get(format!("{typed}:{w}").as_str())
        .copied()
        .unwrap_or(0.);
    if known {
        // Don't decide from a single high-frequency function word or an
        // unfamiliar name to the right. Wait for useful additional context.
        if let Some(c) = c {
            if n(c) == 0. || (d.is_none() && n(c) > 1600. && c.len() <= 3) {
                return None;
            }
            if n(&format!("{typed} {c}")) >= 30. && left_hits < 5. && right_phrase < 5. {
                return None;
            }
        }
        // Altering the length of a valid word needs support on both sides.
        if typed.len() != w.len() && (left_hits < 3. || right_hits < 3.) {
            return None;
        }
        // A real word is the default. For unobserved confusions require an
        // intact two-word continuation that overwhelmingly favours the change.
        if votes < 2.
            && d.is_none()
            && right_hits < 2. * c.map_or(0., |c| n(&format!("{typed} {c}")))
        {
            return None;
        }
        if votes > 0.
            && votes < 5.
            && n(typed) > 200.
            && left_hits < 8. * n(&format!("{b} {typed}")).max(1.)
        {
            return None;
        }
        if w.len() != typed.len() && votes < 8. {
            return None;
        }
        let strong_context = (phrase >= 4. && left_hits >= 4. && right_hits >= 4.)
            || (right_phrase >= 4. && d.is_some())
            || (left_hits >= 2. && right_hits >= 100.);
        if votes < 2. && (!strong_context || best.1 - literal < 6.) {
            return None;
        }
        if !a.is_empty() && n(&format!("{a} {b} {typed}")) >= 2. && n(&format!("{a} {b} {w}")) < 2.
        {
            return None;
        }
        if let Some(c) = c {
            if right_phrase < 4.
                && n(&format!("{typed} {c}")) >= 4.
                && n(&format!("{w} {c}")) <= n(&format!("{typed} {c}"))
            {
                return None;
            }
        }
    }
    if known && c.is_none() {
        return None;
    }
    if !known && c.is_none() && (left_hits < 12. || errors < 2 || best.1 - runner < 2.5) {
        return None;
    }
    if best.1 - runner < 1.75 || best.1 - literal < threshold {
        return None;
    }
    if known && phrase < 2. && right_phrase < 2. && (left_hits < 2. || right_hits < 4.) {
        return None;
    }
    if !known && phrase < 2. && right_phrase < 2. && left_hits.max(right_hits) < 5. {
        return None;
    }
    Some(w)
}
/// 0: no review, 1: confident candidate, 2: await continuation.
/// # Safety
/// Inputs must be valid NUL-terminated strings; out must have capacity writable bytes.
#[no_mangle]
pub unsafe extern "C" fn mb_short_word_v1(
    leading: *const c_char,
    word: *const c_char,
    following: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if leading.is_null() || word.is_null() || following.is_null() || out.is_null() || capacity == 0
    {
        return -1;
    }
    let (Ok(l), Ok(w), Ok(r)) = (
        unsafe { CStr::from_ptr(leading) }.to_str(),
        unsafe { CStr::from_ptr(word) }.to_str(),
        unsafe { CStr::from_ptr(following) }.to_str(),
    ) else {
        return -1;
    };
    if !(2..=3).contains(&w.len())
        || !w.bytes().all(|x| x.is_ascii_lowercase())
        || l.len() > 1024
        || r.len() > 256
        || !risk(w)
    {
        return 0;
    }
    if let Some(best) = score(l, w, r) {
        if super::context21::confusable_meaning(w, best) {
            return 2;
        }
        if best.len() >= capacity {
            return -1;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(best.as_ptr(), out.cast(), best.len());
            *out.add(best.len()) = 0;
        }
        1
    } else {
        2
    }
}

/// An iOS-accepted spelling absent from both corpora is not a typo merely
/// because its nearest neighbour is common.
/// # Safety
/// word must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn mb_short_unseen_v1(word: *const c_char) -> i32 {
    if word.is_null() {
        return 0;
    }
    let Ok(w) = unsafe { CStr::from_ptr(word) }.to_str() else {
        return 0;
    };
    i32::from(w.len() <= 3 && n(w) == 0. && !WORDS.contains_key(w) && !LITERALS.contains_key(w))
}

/// Rank a limited fallback neighbourhood for an unseen, nonword typing error.
/// The caller must use the transformer to confirm any candidate in context.
/// # Safety
/// Same buffer and string requirements as mb_short_word_v1.
#[no_mangle]
pub unsafe extern "C" fn mb_short_pool_v1(
    word: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if word.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    let Ok(w) = unsafe { CStr::from_ptr(word) }.to_str() else {
        return -1;
    };
    if w.len() != 3
        || !w.bytes().all(|c| c.is_ascii_lowercase())
        || n(w) > 0.
        || WORDS.contains_key(w)
        || LITERALS.contains_key(w)
    {
        return 0;
    }
    let Some(all) = INDEX.get(w) else { return 0 };
    let mut pool: Vec<_> = all
        .iter()
        .filter(|(dst, _)| {
            dst.len() == w.len() + 1 && dst.starts_with(&w[..1]) && dst.ends_with(&w[w.len() - 1..])
        })
        .collect();
    pool.sort_by(|a, b| {
        (n(b.0).ln_1p() + 0.35 * b.1.ln_1p())
            .total_cmp(&(n(a.0).ln_1p() + 0.35 * a.1.ln_1p()))
            .then(a.0.cmp(b.0))
    });
    let result = pool
        .into_iter()
        .take(5)
        .map(|v| v.0)
        .collect::<Vec<_>>()
        .join("\t");
    if result.is_empty() || result.len() >= capacity {
        return 0;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(result.as_ptr(), out.cast(), result.len());
        *out.add(result.len()) = 0;
    }
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn context_can_reverse_a_valid_word_decision() {
        assert_eq!(score("The statement ", "if", "work is"), Some("of"));
        assert_eq!(score("Please tell me ", "if", "work ends"), None);
        assert_eq!(score("My coworker ", "id", "getting a"), Some("is"));
        assert_eq!(score("Please bring my ", "id", "badge tomorrow"), None);
        assert_eq!(score("Can you go ", "be", "with me"), None);
    }
}

/// Whether the proposed correction came only from the new contextual evidence.
/// # Safety
/// All four arguments must point to valid NUL-terminated strings.
#[no_mangle]
pub unsafe extern "C" fn mb_short_new_readout_v1(
    left: *const c_char,
    typed: *const c_char,
    right: *const c_char,
    chosen: *const c_char,
) -> i32 {
    if left.is_null() || typed.is_null() || right.is_null() || chosen.is_null() {
        return 0;
    }
    let parse = |p| unsafe { CStr::from_ptr(p) }.to_str();
    let (Ok(l), Ok(t), Ok(r), Ok(w)) = (parse(left), parse(typed), parse(right), parse(chosen))
    else {
        return 0;
    };
    if l.len() > 1024 || r.len() > 256 || t.len() > 3 || w.len() > 4 {
        return 0;
    }
    i32::from(legacy_score(l, t, r) != Some(w))
}
