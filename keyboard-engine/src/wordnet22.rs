//! Character/subword neural ranker. Float scales and signed byte weights are
//! exported by train_wordnet22.py. Nothing typed is saved by this module.
use super::{c_char, CStr, HashMap, LazyLock, WORDS};
const BINS: usize = 32768;
const D: usize = 48;
const H: usize = 112;
const K: usize = 48;
static VOCAB: LazyLock<Vec<&str>> = LazyLock::new(|| {
    include_str!("../model/wordnet22/vocab.txt")
        .lines()
        .collect()
});
static FORMS: LazyLock<HashMap<&str, &str>> = LazyLock::new(|| {
    include_str!("../model/wordnet22/forms.tsv")
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .collect()
});
static CONTEXT: LazyLock<HashMap<&str, u32>> = LazyLock::new(|| {
    include_str!("../model/wordnet22/context.tsv")
        .lines()
        .filter_map(|l| {
            let (w, n) = l.split_once('\t')?;
            Some((w, n.parse().ok()?))
        })
        .collect()
});
fn count(k: &str) -> u32 {
    CONTEXT.get(k).copied().unwrap_or(0)
}
struct Model {
    scale: Vec<f32>,
    embed: &'static [u8],
    a: Vec<f32>,
    scores: &'static [u8],
    s: Vec<f32>,
    ab: Vec<f32>,
    bb: Vec<f32>,
}
static MODEL: LazyLock<Model> = LazyLock::new(|| {
    let mut blob: &'static [u8] = include_bytes!("../model/wordnet22/weights.bin");
    fn take(blob: &mut &'static [u8], n: usize) -> &'static [u8] {
        let (a, b) = blob.split_at(n);
        *blob = b;
        a
    }
    fn float(blob: &mut &'static [u8], n: usize) -> Vec<f32> {
        take(blob, n * 4)
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
            .collect()
    }
    let dims: Vec<_> = take(&mut blob, 20)
        .chunks_exact(4)
        .map(|a| u32::from_le_bytes(a.try_into().unwrap()) as usize)
        .collect();
    let n = VOCAB.len();
    assert_eq!(dims, [BINS, D, H, n, K]);
    let scale = float(&mut blob, BINS);
    let embed = take(&mut blob, BINS * D);
    let ascale = float(&mut blob, H);
    let a = take(&mut blob, H * 5 * D)
        .iter()
        .enumerate()
        .map(|(i, &q)| q as i8 as f32 * ascale[i / (5 * D)])
        .collect();
    let s = float(&mut blob, n);
    let scores = take(&mut blob, n * H);
    let ab = float(&mut blob, H);
    let bb = float(&mut blob, n);
    assert!(blob.is_empty());
    Model {
        scale,
        embed,
        a,
        scores,
        s,
        ab,
        bb,
    }
});
fn encode(w: &str, out: &mut [f32]) {
    if w.is_empty() {
        return;
    }
    let mut v = [0u8; 30];
    v[0] = b'^';
    let n = w.len().min(28);
    v[1..n + 1].copy_from_slice(&w.as_bytes()[..n]);
    v[n + 1] = b'$';
    let v = &v[..n + 2];
    let mut cnt = 0;
    let mut add = |g: &[u8]| {
        let h = g.iter().fold(2166136261u32, |h, b| {
            (h ^ u32::from(*b)).wrapping_mul(16777619)
        });
        let id = 1 + h as usize % (BINS - 1);
        let s = MODEL.scale[id];
        for (x, &q) in out.iter_mut().zip(&MODEL.embed[id * D..(id + 1) * D]) {
            *x += s * q as i8 as f32;
        }
    };
    add(v);
    cnt += 1;
    'grams: for n in [3, 2, 4, 1] {
        for g in v.windows(n) {
            if cnt == K {
                break 'grams;
            }
            add(g);
            cnt += 1;
        }
    }
    let norm = 1. / (cnt as f32).sqrt();
    for x in out {
        *x *= norm;
    }
}
fn infer(words: [&str; 5]) -> (usize, f32, f32) {
    let mut x = [0f32; 5 * D];
    for (i, w) in words.iter().enumerate() {
        encode(w, &mut x[i * D..(i + 1) * D]);
    }
    let mut h = [0f32; H];
    for (i, row) in MODEL.a.chunks_exact(5 * D).enumerate() {
        h[i] = (MODEL.ab[i] + row.iter().zip(x.iter()).map(|(a, x)| a * x).sum::<f32>()).max(0.);
    }
    let sc = h.iter().copied().fold(0f32, f32::max).max(1e-8) / 127.;
    let q = h.map(|x| (x / sc).round() as i8);
    let (mut best, mut top, mut runner) = (0, f32::NEG_INFINITY, f32::NEG_INFINITY);
    for (i, r) in MODEL.scores.chunks_exact(H).enumerate() {
        let dot: i32 = r
            .iter()
            .zip(q.iter())
            .map(|(&a, &b)| i32::from(a as i8) * i32::from(b))
            .sum();
        let v = dot as f32 * sc * MODEL.s[i] + MODEL.bb[i];
        if v > top {
            runner = top;
            top = v;
            best = i
        } else {
            runner = runner.max(v)
        }
    }
    (best, top, top - runner)
}
pub(super) fn distance(a: &str, b: &str) -> usize {
    if a.len() > 30 || b.len() > 30 {
        return 99;
    }
    let mut row = [0u8; 31];
    for (j, v) in row.iter_mut().enumerate() {
        *v = j as u8
    }
    let mut prev = row;
    for (i, &ac) in a.as_bytes().iter().enumerate() {
        let old = row;
        row[0] = (i + 1) as u8;
        for (j, &bc) in b.as_bytes().iter().enumerate() {
            let mut cost = (row[j] + 1)
                .min(old[j + 1] + 1)
                .min(old[j] + u8::from(ac != bc));
            if i > 0 && j > 0 && ac == b.as_bytes()[j - 1] && a.as_bytes()[i - 1] == bc {
                cost = cost.min(prev[j - 1] + 1)
            }
            row[j + 1] = cost
        }
        prev = old;
    }
    row[b.len()] as usize
}
fn toks(s: &str) -> impl DoubleEndedIterator<Item = &str> {
    s.split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|s| !s.is_empty())
}
pub(super) fn decision(
    leading: &str,
    typed: &str,
    following: &str,
    accepted: bool,
) -> Option<String> {
    if typed.is_empty()
        || typed.len() > 25
        || !typed.bytes().all(|c| c.is_ascii_alphabetic() || c == 39)
    {
        return None;
    }
    if typed.len() > 1 && typed.bytes().all(|b| b.is_ascii_uppercase()) {
        return None;
    }
    let l = leading.to_ascii_lowercase();
    let t = typed.to_ascii_lowercase();
    let r = following.to_ascii_lowercase();
    let mut left = toks(
        l.rsplit(['.', '?', '!', '\n', ';', ':'])
            .next()
            .unwrap_or(""),
    )
    .rev();
    let p = left.next().unwrap_or("");
    let pp = left.next().unwrap_or("");
    let mut right = toks(
        r.split(['.', '?', '!', '\n', ';', ':'])
            .next()
            .unwrap_or(""),
    );
    let n = right.next().unwrap_or("");
    let nn = right.next().unwrap_or("");
    let (id, _, margin) = infer([&t, p, pp, n, nn]);
    if id == 0 {
        return None;
    }
    let w = VOCAB[id];
    let dist = distance(&t, w);
    let left2 = count(&format!(
        "{} {} {w}",
        if pp.is_empty() { "^" } else { pp },
        if p.is_empty() { "^" } else { p }
    ));
    let lead = count(&format!("{} {w}", if p.is_empty() { "^" } else { p }));
    let tail = if n.is_empty() {
        0
    } else {
        count(&format!("{w} {n}"))
    };
    let middle = if n.is_empty() {
        0
    } else {
        count(&format!("{p} {w} {n}"))
    };
    let right2 = if nn.is_empty() {
        0
    } else {
        count(&format!("{w} {n} {nn}"))
    };
    let frame = left2.max(middle).max(right2);
    let case = FORMS.get(w).copied().unwrap_or(w);
    if w == t {
        if case == typed || case == w || margin < 4. || frame < 2 && lead.min(tail) < 2 {
            return None;
        }
        return Some(case.to_owned());
    }
    let mixed = typed.bytes().skip(1).any(|c| c.is_ascii_uppercase());
    if mixed && (margin < 5. || frame < 4) {
        return None;
    }
    if dist
        > if t.len().max(w.len()) >= 7 {
            4
        } else if t.len().max(w.len()) >= 4 {
            3
        } else {
            2
        }
    {
        return None;
    }
    if margin < if accepted { 5.3 } else { 2.7 } {
        return None;
    }
    if lead == 0 && tail == 0 || accepted && (frame < 2 && lead.min(tail) < 3) {
        return None;
    }
    if accepted && !p.is_empty() && count(&format!("{p} {t} {n}")) >= 2 {
        return None;
    }
    if accepted && WORDS.contains_key(t.as_str()) && n.is_empty() && (frame < 7 || margin < 8.) {
        return None;
    }
    // Unknown people's names, accepted keyboard spellings, or near-homophones
    // need an attested context. A high character-model score alone isn't enough.
    if typed.as_bytes()[0].is_ascii_uppercase()
        && !p.is_empty()
        && case == w
        && (frame < 4 || margin < 6.)
    {
        return None;
    }
    let form = if case != w {
        case.to_owned()
    } else if (typed.as_bytes()[0].is_ascii_uppercase() && p.is_empty())
        || (p.is_empty() && frame >= 5 && margin > 5.)
    {
        let mut s = w.to_owned();
        s[..1].make_ascii_uppercase();
        s
    } else {
        w.to_owned()
    };
    Some(form)
}
/// # Safety
/// Inputs are NUL-terminated UTF-8 and out holds capacity writable bytes.
#[no_mangle]
pub unsafe extern "C" fn mb_wordnet22_v1(
    l: *const c_char,
    t: *const c_char,
    r: *const c_char,
    accepted: i32,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if l.is_null() || t.is_null() || r.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    let read = |p| unsafe { CStr::from_ptr(p) }.to_str();
    let (Ok(l), Ok(t), Ok(r)) = (read(l), read(t), read(r)) else {
        return -1;
    };
    if l.len() > 640 || r.len() > 256 {
        return 0;
    }
    let Some(s) = decision(l, t, r, accepted != 0) else {
        return 0;
    };
    if s.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(s.as_ptr(), out.cast(), s.len());
        *out.add(s.len()) = 0;
    }
    1
}

/// Estimate whether local context is represented in the paired training
/// distribution. This is a backoff gate, not a lookup of whole sentences.
fn local_support(input: &str) -> (i32, i32, i32) {
    let s = input.to_ascii_lowercase().replace('’', "'");
    let ws: Vec<_> = toks(&s).collect();
    if ws.is_empty() {
        return (0, 0, 0);
    }
    let mut hits = 0;
    let mut triples = 0;
    let mut content = 0;
    for i in 0..ws.len() {
        let w = ws[i];
        let p = if i > 0 { ws[i - 1] } else { "^" };
        let pp = if i > 1 { ws[i - 2] } else { "^" };
        if count(&format!("{p} {w}")) >= 2 {
            hits += 1;
        }
        if i >= 1 && count(&format!("{pp} {p} {w}")) >= 2 {
            triples += 1;
            if w.len().max(p.len()) >= 4 {
                content += 1
            }
        }
    }
    (100 * hits / ws.len() as i32, triples, content)
}
fn in_domain(s: &str) -> bool {
    let (bi, tri, content) = local_support(s);
    bi >= 72 && tri >= 2 && content >= 1
}
// The first key has no left neighbor. Require a unique trained confusion
// and two independent counts involving the following keys before rewriting it.
fn opening_form(raw: &str, next: &str, after: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    if !(2..=8).contains(&bytes.len()) || !bytes[0].is_ascii_uppercase()
        || !bytes.iter().all(|b| b.is_ascii_alphabetic() || *b == 39) { return None; }
    let w = raw.to_ascii_lowercase();
    let n = next.to_ascii_lowercase();
    let nn = after.to_ascii_lowercase();
    let supported = |x: &str| count(&format!("^ {x} {n}")) >= 4 && count(&format!("{x} {n} {nn}")) >= 2;
    let mixed = bytes[1].is_ascii_uppercase() && bytes.len()>2 && bytes[2..].iter().all(u8::is_ascii_lowercase);
    let target = if mixed && super::surface31::normally_lower(&w) && (supported(&w) || count(&format!("^ ^ {w}")) >= 100) { w.as_str() } else {
        // Keep ordinary words, initials and genuine uppercase names. Only a
        // repeated upper-case stroke is allowed to stand in for a single key.
        let repeated = bytes.len() == 2 && bytes[0] == bytes[1];
        if (WORDS.contains_key(w.as_str()) || raw.len()>2 && bytes.iter().all(u8::is_ascii_uppercase)) && !repeated { return None; }
        let mut options = super::denoise22::observed_single(&w).filter(|(x, hits)|
            *hits >= 3. && x.len().abs_diff(w.len()) <= 1 && (!repeated || x.len()==1) && supported(x));
        let (target, _) = options.next()?;
        if options.next().is_some() { return None; }
        target
    };
    let mut out = target.to_owned();
    out[..1].make_ascii_uppercase();
    (out != raw).then_some(out)
}

// Repair an accidental internal space only when the contiguous spelling has
// strong context on both sides and at least one fragment isn't a known word.
// Apply to the original boundaries before a fragment can get its own correction.
fn prepare_span(raw: &str) -> Option<String> {
    let mut words: Vec<String> = raw.split(' ').map(str::to_owned).collect();
    if words.len() < 3 || words.len() > 12 { return None; }
    let mut changed = false;
    if let Some(form) = opening_form(&words[0], &words[1], &words[2]) { words[0]=form; changed=true; }
    let t = words[0].as_bytes();
    if (3..=8).contains(&t.len()) && t[0].is_ascii_uppercase() && t[1].is_ascii_uppercase()
        && t[2..].iter().all(u8::is_ascii_lowercase) {
        let mut matches = Vec::new();
        for remove in [0, 1] {
            let mut form = words[0].clone(); form.remove(remove);
            let w = form.to_ascii_lowercase();
            let n = words[1].to_ascii_lowercase();
            let nn = words[2].to_ascii_lowercase();
            if !matches.contains(&form) && WORDS.contains_key(w.as_str()) &&
                count(&format!("^ {w} {n}")) >= 4 && count(&format!("{w} {n} {nn}")) >= 2 &&
                (t[0] == t[1] || super::denoise22::attestation(&words[0].to_ascii_lowercase(), &w) >= 2.) {
                matches.push(form);
            }
        }
        if matches.len()==1 && !WORDS.contains_key(words[0].to_ascii_lowercase().as_str()) {
            words[0] = matches.pop().unwrap(); changed=true;
        }
    }
    let mut i=1;
    while i+2<words.len() {
        let (a,b)=(&words[i],&words[i+1]);
        if a.len()>=2 && b.len()>=2 && a.len()+b.len()<=20 &&
            a.bytes().chain(b.bytes()).all(|c|c.is_ascii_lowercase()) &&
            (!WORDS.contains_key(a.as_str()) || !WORDS.contains_key(b.as_str())) {
            let joint=format!("{a}{b}");
            let prev=words[i-1].to_ascii_lowercase(); let next=words[i+2].to_ascii_lowercase();
            if WORDS.contains_key(joint.as_str()) && count(&format!("{prev} {joint} {next}"))>=2 &&
                count(&format!("{prev} {joint}")) >=4 && count(&format!("{joint} {next}"))>=4 &&
                count(&format!("{a} {b}"))==0 {
                words[i]=joint; words.remove(i+1); changed=true;
            }
        }
        i+=1;
    }
    changed.then(||words.join(" "))
}

pub(super) fn pipeline(raw: &str) -> Option<String> {
    if raw.len() > 180 || raw.is_empty() {
        return None;
    }
    let original_input = raw;
    let prepared = prepare_span(raw);
    let raw = prepared.as_deref().unwrap_or(raw);
    // Replacing the opening changes the decoder's domain/beam. Keep a
    // previously available spelling repair for another token if both lexical
    // alignment and independent typing-error observations confirm it.
    if prepared.is_some() {
        let original: Vec<_> = original_input.split(' ').collect();
        let altered: Vec<_> = raw.split(' ').collect();
        if original.len() == altered.len() && original.first() != altered.first()
            && original.iter().skip(1).eq(altered.iter().skip(1)) {
            let old = decode_span(original_input, original_input, None);
            let new = decode_span(raw, original_input, prepared.clone());
            if let (Some(first), Some(second)) = (old.as_deref(), new.as_deref()) {
                let prior: Vec<_> = first.split(' ').collect();
                let mut now: Vec<_> = second.split(' ').collect();
                if prior.len()==original.len() && now.len()==original.len() {
                    for i in 1..now.len() {
                        let input=original[i].to_ascii_lowercase();
                        let restored=prior[i].to_ascii_lowercase();
                        if input != restored && prior[i] != now[i] && !WORDS.contains_key(input.as_str())
                            && super::denoise22::attestation(&input, &restored) >= 2.
                            && (now[i] == original[i] || super::denoise22::attestation(&input, &now[i].to_ascii_lowercase()) == 0.) {
                            now[i]=prior[i];
                        }
                    }
                    return Some(now.join(" "));
                }
            }
            return new;
        }
    }
    decode_span(raw, original_input, prepared.clone())
}

fn decode_span(raw: &str, original_input: &str, prepared: Option<String>) -> Option<String> {
    let seq = super::denoise22::decode(raw);
    let mut out = seq.as_deref().unwrap_or(raw).to_owned();
    // In a badly damaged sentence two independent repairs sometimes have to
    // agree before any three adjacent words are recognizable.
    let represented = |text: &str| {
        let (bi, tri, content) = local_support(text);
        in_domain(text)
            || (bi >= 53 && tri >= 1 && content >= 1 && text != raw && {
                let source = raw.split_whitespace().collect::<Vec<_>>();
                let dest = text.split_whitespace().collect::<Vec<_>>();
                source.len() == dest.len()
                    && source.iter().zip(&dest).any(|(&a, &b)| {
                        a != b
                            && a.len() > 3
                            && !WORDS.contains_key(a.to_ascii_lowercase().as_str())
                            && VOCAB
                                .binary_search(&a.to_ascii_lowercase().as_str())
                                .is_err()
                    })
            })
    };
    if let Some(next) = super::refine26::refine(raw, &out) {
        out = next;
    }
    if let Some(next) = super::surface31::refine(raw, &out) {
        out = next;
    }
    if let Some(next) = super::window34::refine(raw, &out) {
        if represented(&next) || represented(&out) || local_support(&next).1 >= 1 {
            out = next;
        }
    }
    if !represented(&out) && !in_domain(raw) {
        return prepared;
    }
    if out != raw {
        if let Some(next) = super::denoise22::decode(&out) {
            let from = local_support(&out);
            let to = local_support(&next);
            // Do not cascade an unrelated substitution merely because the
            // new text is pronounceable. Require additional phrase evidence.
            if to.1 > from.1 && to.0 >= from.0 && to.2 >= from.2 {
                out = next
            }
        }
    }
    // A second, independently fitted character model can recover an unfamiliar
    // spelling that was outside the lattice's edit radius. Score only retained
    // words; keep each role's own input separate from its proposed output.
    let words: Vec<&str> = out.split(' ').collect();
    let mut changed: Vec<String> = words.iter().map(|w| w.to_string()).collect();
    for (i, &token) in words.iter().enumerate() {
        if token.len() < 1
            || token.len() > 24
            || !raw.split(' ').any(|w| w == token)
            || !token.bytes().all(|b| b.is_ascii_alphabetic() || b == 39)
        {
            continue;
        }
        let lower = token.to_ascii_lowercase();
        let known =
            WORDS.contains_key(lower.as_str()) || VOCAB.binary_search(&lower.as_str()).is_ok();
        let left = words[..i].join(" ");
        let right = words[i + 1..].join(" ");
        if known && (right.is_empty() || i == 0) {
            continue;
        }
        if let Some(rep) = decision(&left, token, &right, known) {
            let w = rep.to_ascii_lowercase();
            let prev = if i == 0 {
                "^".to_owned()
            } else {
                words[i - 1].to_ascii_lowercase()
            };
            let next = words
                .get(i + 1)
                .map(|s| s.to_ascii_lowercase())
                .unwrap_or_else(|| "$".to_owned());
            let old = count(&format!("{prev} {lower} {next}"));
            let new = count(&format!("{prev} {w} {next}"));
            if known
                && (new < 4
                    || old > 0
                    || count(&format!("{prev} {lower}")) >= 2
                        && count(&format!("{lower} {next}")) >= 2)
            {
                continue;
            }
            changed[i] = rep;
        }
    }
    out = changed.join(" ");
    if out != original_input {
        // Restore sentence casing only when an independent spelling edit was
        // made and the initial 3-word sequence is strongly attested.
        if let Some(ch) = out.as_bytes().first().copied() {
            if ch.is_ascii_lowercase()
                && local_support(&out).1 >= 2
                && !out.eq_ignore_ascii_case(original_input)
            {
                out[..1].make_ascii_uppercase();
            }
        }
    }
    Some(out)
}
/// 1: covered context (including an intentional literal); 0: defer to the other models.
/// # Safety
/// Input and output obey the same UTF-8 C string contract as mb_wordnet22_v1.
#[no_mangle]
pub unsafe extern "C" fn mb_pipeline22_v1(
    input: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if input.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    let Ok(t) = unsafe { CStr::from_ptr(input) }.to_str() else {
        return -1;
    };
    let Some(s) = pipeline(t) else { return 0 };
    if s.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(s.as_ptr(), out.cast(), s.len());
        *out.add(s.len()) = 0;
    }
    1
}

// Repeated literal usage in independent casual conversations is a reason to
// leave an unusual token intact; no phrases or raw messages are retained.
static CASUAL: LazyLock<HashMap<&str, u32>> = LazyLock::new(|| {
    include_str!("../model/wordnet22/casual.tsv")
        .lines()
        .filter_map(|l| {
            let (w, n) = l.split_once('\t')?;
            Some((w, n.parse().ok()?))
        })
        .collect()
});
/// # Safety
/// Arguments must point to NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn mb_casual_keep_v1(
    left: *const c_char,
    word: *const c_char,
    suggestion: *const c_char,
) -> i32 {
    if left.is_null() || word.is_null() || suggestion.is_null() {
        return 0;
    }
    let read = |p| unsafe { CStr::from_ptr(p) }.to_str();
    let (Ok(l), Ok(w), Ok(s)) = (read(left), read(word), read(suggestion)) else {
        return 0;
    };
    if l.len() > 640 || w.len() > 32 || s.len() > 48 {
        return 0;
    }
    let low = w.to_ascii_lowercase();
    let dest = s.to_ascii_lowercase();
    if w == s {
        return 0;
    }
    let left = l.to_ascii_lowercase();
    let p = toks(&left).next_back().unwrap_or("^");
    let sum = CASUAL.get(low.as_str()).copied().unwrap_or(0);
    let hits = CASUAL
        .get(format!("{p} {low}").as_str())
        .copied()
        .unwrap_or(0);
    let normalized = dest.chars().filter(|c| *c != '\'').collect::<String>();
    if normalized == low
        && dest.contains('\'')
        && CASUAL.get(dest.as_str()).copied().unwrap_or(0) >= sum.max(1) * 2
    {
        return 0;
    }
    if sum >= 4
        && (w == low && (low == dest || (normalized == low && dest.contains('\''))) || hits >= 2)
    {
        return 1;
    }
    i32::from(sum >= 4 && count(&format!("{p} {low}")) > 0 && count(&format!("{p} {dest}")) == 0)
}

/// Read both sides of the word from the caller's short, validated typing span.
/// # Safety
/// Strings are UTF-8 and NUL-terminated. The caller owns capacity bytes at out.
#[no_mangle]
pub unsafe extern "C" fn mb_real25_v1(
    left: *const c_char,
    word: *const c_char,
    right: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if left.is_null() || word.is_null() || right.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    let read = |p| unsafe { CStr::from_ptr(p) }.to_str();
    let (Ok(l), Ok(w), Ok(r)) = (read(left), read(word), read(right)) else {
        return -1;
    };
    if l.len() > 512 || r.len() > 180 {
        return 0;
    }
    let Some(s) = super::real25::repair(l, w, r)
        .or_else(|| super::cloze27::repair(l, w, r))
        .or_else(|| super::contrast40::repair(l, w, r))
        .or_else(|| super::evidence45::repair(l, w, r)) else {
        return 0;
    };
    if s.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(s.as_ptr(), out.cast(), s.len());
        *out.add(s.len()) = 0;
    }
    1
}

/// Read both sides of the word from the caller's short, validated typing span.
/// # Safety
/// Strings are UTF-8 and NUL-terminated. The caller owns capacity bytes at out.
#[no_mangle]
pub unsafe extern "C" fn mb_textspell30_v1(
    left: *const c_char,
    word: *const c_char,
    right: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if left.is_null() || word.is_null() || right.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    let read = |p| unsafe { CStr::from_ptr(p) }.to_str();
    let (Ok(l), Ok(w), Ok(r)) = (read(left), read(word), read(right)) else {
        return -1;
    };
    if l.len() > 512 || r.len() > 180 {
        return 0;
    }
    let Some(s) = super::textspell30::repair(l, w, r) else {
        return 0;
    };
    if s.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(s.as_ptr(), out.cast(), s.len());
        *out.add(s.len()) = 0;
    }
    1
}

/// Veto a late substitution when the typed form has substantially stronger
/// contiguous phrase support than its rival. No full sentences are stored.
pub(super) fn literal_supported(left: &str, word: &str, right: &str, replacement: &str) -> bool {
    let (l, w, r, s) = (
        left.to_ascii_lowercase(),
        word.to_ascii_lowercase(),
        right.to_ascii_lowercase(),
        replacement.to_ascii_lowercase(),
    );
    if w == s || w.contains(' ') || s.contains(' ') {
        return false;
    }
    if super::evidence45::protects(&l, &w, &r, &s) { return true; }
    let left_part = l
        .rsplit(['.', '?', '!', ';', ':', '\n'])
        .next()
        .unwrap_or("");
    let mut before = toks(left_part).rev();
    let p = before.next().unwrap_or("^");
    let pp = before.next().unwrap_or("^");
    let mut after = toks(
        r.split(['.', '?', '!', ';', ':', '\n'])
            .next()
            .unwrap_or(""),
    );
    let n = after.next().unwrap_or("$");
    let nn = after.next().unwrap_or("$");
    let support = |v: &str| {
        let trailing = count(&format!("{pp} {p} {v}"));
        let middle = count(&format!("{p} {v} {n}"));
        let leading = count(&format!("{v} {n} {nn}"));
        if n != "$" {
            middle.max(leading)
        } else {
            trailing
        }
    };
    let a = support(&w);
    let b = support(&s);
    a >= 3 && a >= 4 * b.max(1)
}
/// # Safety
/// Arguments must point to NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn mb_literal_supported_v1(
    l: *const c_char,
    t: *const c_char,
    r: *const c_char,
    s: *const c_char,
) -> i32 {
    if [l, t, r, s].iter().any(|p| p.is_null()) {
        return 0;
    }
    let read = |p| unsafe { CStr::from_ptr(p) }.to_str();
    match (read(l), read(t), read(r), read(s)) {
        (Ok(l), Ok(t), Ok(r), Ok(s))
            if l.len() <= 8192 && r.len() <= 500 && t.len() <= 32 && s.len() <= 48 =>
        {
            i32::from(literal_supported(l, t, r, s))
        }
        _ => 0,
    }
}

/// Veto a dictionary-to-dictionary rewrite from the noisy sentence decoder if
/// the alternate has no supporting mistake observations or contextual agreement. A preceding typo can otherwise
/// turn a good noun into a more frequent one (e.g. on an unfamiliar topic).
#[no_mangle]
pub unsafe extern "C" fn mb_uncorroborated_v1(
    left: *const c_char,
    word: *const c_char,
    right: *const c_char,
    proposal: *const c_char,
) -> i32 {
    if [left, word, right, proposal].iter().any(|p| p.is_null()) {
        return 0;
    }
    let read = |p| unsafe { CStr::from_ptr(p) }.to_str();
    let (Ok(l), Ok(w), Ok(r), Ok(s)) = (read(left), read(word), read(right), read(proposal)) else {
        return 0;
    };
    if w.len() < 2
        || w.len() > 16
        || s.len() > 20
        || !w.bytes().all(|c| c.is_ascii_alphabetic())
        || !s.bytes().all(|c| c.is_ascii_alphabetic())
    {
        return 0;
    }
    let a = w.to_ascii_lowercase();
    let b = s.to_ascii_lowercase();
    if a == b || (!WORDS.contains_key(a.as_str()) && VOCAB.binary_search(&a.as_str()).is_err()) {
        return 0;
    }
    let low_l = l.to_ascii_lowercase();
    let low_r = r.to_ascii_lowercase();
    let p = toks(&low_l).next_back().unwrap_or("^");
    let n = toks(&low_r).next().unwrap_or("$");
    let observed = super::denoise22::attestation(&a, &b);
    if observed >= 2.
        && (count(&format!("{p} {b} {n}")) >= 3
            || count(&format!("{p} {b}")) >= 2 && count(&format!("{b} {n}")) >= 2)
    {
        return 0;
    }
    let neural = super::real25::repair(l, &a, r).as_deref() == Some(b.as_str());
    let counts = super::cloze27::repair(l, &a, r).as_deref() == Some(b.as_str());
    i32::from(!(neural && counts || observed >= 2. && (neural || counts)))
}

/// Whether a proposed form is attested as lowercase inside clean messages.
/// # Safety
/// The caller supplies a NUL-terminated UTF-8 word.
#[no_mangle]
pub unsafe extern "C" fn mb_midword_lowercase_v1(word: *const c_char) -> i32 {
    if word.is_null() { return 0; }
    let Ok(w) = (unsafe { CStr::from_ptr(word) }).to_str() else { return 0 };
    i32::from(super::surface31::normally_lower(w))
}

/// A casual left bigram is weak evidence once a full, independently observed
/// context is available. Compare actual literal and proposed phrases, requiring
/// agreement with the calibrated real-word classifier.
/// # Safety
/// Arguments must point to NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn mb_context_agrees_v1(left:*const c_char, word:*const c_char, right:*const c_char, guess:*const c_char)->i32 {
    if [left,word,right,guess].iter().any(|p|p.is_null()) { return 0; }
    let read=|p| unsafe{CStr::from_ptr(p)}.to_str();
    let (Ok(l),Ok(w),Ok(r),Ok(g))=(read(left),read(word),read(right),read(guess)) else{return 0;};
    if super::evidence45::repair(l,w,r).as_deref()==Some(g) { return 1; }
    if w.len()>7 || g.len()>8 || l.len()>640 || r.len()>256 || !w.bytes().all(|c|c.is_ascii_lowercase()) ||
        super::contrast40::repair(l,w,r).as_deref()!=Some(g) {return 0;}
    let l=l.rsplit(['.','!','?',';',':','\n']).next().unwrap_or("").to_ascii_lowercase();
    let r=r.split(['.','!','?',';',':','\n']).next().unwrap_or("").to_ascii_lowercase();
    let mut before=toks(&l).rev();
    let (Some(p),Some(pp),Some(n))=(before.next(),before.next(),toks(&r).next()) else{return 0;};
    let votes=|x:&str| (count(&format!("{pp} {p} {x}")),count(&format!("{p} {x} {n}")));
    let (a,b)=votes(w); let (aa,bb)=votes(g);
    i32::from(a==0 && b==0 && aa>=4 && bb>=4)
}


/// # Safety
/// Both arguments must point to NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn mb_supported_opening_v1(span: *const c_char, proposed: *const c_char) -> i32 {
    if span.is_null() || proposed.is_null() { return 0; }
    let (Ok(raw), Ok(guess)) = (unsafe { CStr::from_ptr(span) }.to_str(), unsafe { CStr::from_ptr(proposed) }.to_str()) else { return 0; };
    if raw.len() > 180 || guess.len() > 12 { return 0; }
    let mut words = raw.split(' ');
    let (Some(w), Some(n), Some(nn)) = (words.next(), words.next(), words.next()) else { return 0; };
    i32::from(opening_form(w, n, nn).as_deref() == Some(guess))
}
