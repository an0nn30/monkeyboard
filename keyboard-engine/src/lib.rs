//! Stateless English lexical and contextual ranking. No network or user data storage.
mod context21;
mod contractions;
mod rejoin53;
mod frames53;
mod literal53;
#[cfg(feature = "lm-neural")]
mod neural;
#[cfg(feature = "lm-neural")]
mod semantics;
mod short_words;
mod cloze27;
mod contrast40;
mod evidence45;
mod refine26;
mod surface31;
mod window34;
mod real25;
mod textspell30;
mod wordnet22;
mod denoise22;
mod spelling22;
use std::{
    collections::{HashMap, HashSet},
    ffi::{c_char, CStr},
    sync::LazyLock,
};
type Counts = HashMap<&'static str, u32>;
static WORDS: LazyLock<Counts> = LazyLock::new(|| {
    include_str!("../model/words.tsv")
        .lines()
        .filter_map(|l| {
            let (w, n) = l.split_once('\t')?;
            Some((w, n.parse().ok()?))
        })
        .collect()
});
type Contexts = HashMap<&'static str, Vec<(&'static str, u32)>>;
static NEXT: LazyLock<Contexts> =
    LazyLock::new(|| load_contexts(include_str!("../model/next.tsv")));
// Keep variable-length candidate lists in the read-only table. A sorted row
// index avoids allocating ~42,000 separate vectors on the first keystroke.
static PREDICT: LazyLock<Vec<(&str, &str)>> = LazyLock::new(|| {
    include_str!("../model/predict.tsv")
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .collect()
});
// Counts learned from S:/C: pairs are stored separately so the texting
// corpus can contribute a bounded amount of evidence to the decoder.
static PAIRED_NEXT: LazyLock<Vec<(&str, &str)>> = LazyLock::new(|| {
    include_str!("../model/paired-next.tsv")
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .collect()
});
static PAIRED_EDITS: LazyLock<Vec<(&str, &str)>> = LazyLock::new(|| {
    include_str!("../model/paired-edits.tsv")
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .collect()
});
// Repeated mistakes seen in independent training messages. Prefer a local
// spelling before one that wins across contexts; the caller protects real words.
static ATTESTED: LazyLock<Vec<(&str, &str)>> = LazyLock::new(|| {
    include_str!("../model/attested-edits.tsv")
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .collect()
});
fn attested(context: &str, word: &str) -> Option<&'static str> {
    if !(2..=30).contains(&word.len()) || !word.bytes().all(|b| b.is_ascii_lowercase()) {
        return None;
    }
    let (_, prev) = history(context);
    let prefix = if prev.is_empty() { "^" } else { prev.as_str() };
    let lookup = |p: &str| {
        let key = format!("{p}:{word}");
        ATTESTED
            .binary_search_by_key(&key.as_str(), |r| r.0)
            .ok()
            .map(|i| ATTESTED[i].1)
    };
    lookup(&format!("!{prefix}"))
        .or_else(|| lookup(prefix))
        .or_else(|| {
            let repair = lookup("*")?;
            let first = repair.split_whitespace().next()?;
            let phrase = format!("!{prefix}:{first}");
            ATTESTED
                .binary_search_by_key(&phrase.as_str(), |row| row.0)
                .ok()
                .map(|_| repair)
        })
}
/// Returns one attested candidate in the caller's buffer. No result is retained.
/// # Safety
/// Both inputs must be NUL-terminated; out must point to capacity writable bytes.
#[no_mangle]
pub unsafe extern "C" fn mb_attested_v1(
    context: *const c_char,
    word: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if context.is_null() || word.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    unsafe {
        *out = 0;
    }
    let (Ok(ctx), Ok(w)) = (
        unsafe { CStr::from_ptr(context) }.to_str(),
        unsafe { CStr::from_ptr(word) }.to_str(),
    ) else {
        return -1;
    };
    if ctx.len() > 2048 {
        return -1;
    }
    let Some(found) = attested(ctx, w) else {
        return 0;
    };
    if found.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(found.as_ptr(), out.cast(), found.len());
        *out.add(found.len()) = 0;
    }
    1
}
fn load_contexts(table: &'static str) -> Contexts {
    table
        .lines()
        .filter_map(|l| {
            let (k, vs) = l.split_once('\t')?;
            Some((
                k,
                vs.split_whitespace()
                    .filter_map(|v| {
                        let (w, n) = v.split_once(':')?;
                        Some((w, n.parse().ok()?))
                    })
                    .collect(),
            ))
        })
        .collect()
}
static DISPLAY: LazyLock<HashSet<&'static str>> = LazyLock::new(|| {
    include_str!("../training/display-words.txt")
        .split_whitespace()
        .collect()
});
fn history(context: &str) -> (String, String) {
    let lower = context
        .trim_end_matches([' ', '\t'])
        .to_ascii_lowercase()
        .replace('’', "'");
    let mut it = lower
        .rsplit(['.', '!', '?', '\n', ';', ':'])
        .next()
        .unwrap_or("")
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|s| !s.is_empty())
        .rev();
    let b = it.next().unwrap_or("");
    (
        it.next().map(|a| format!("{a} {b}")).unwrap_or_default(),
        b.to_owned(),
    )
}
// Longer matches help distinguish "pick you up" from generic "you …".
// Mix in shorter histories rather than filling every slot from a rare phrase.
fn next_words(context: &str) -> Vec<&'static str> {
    let tail = context
        .trim_end_matches([' ', '\t'])
        .to_ascii_lowercase()
        .replace('’', "'");
    let sentence = tail
        .rsplit(['.', '!', '?', '\n', ';', ':'])
        .next()
        .unwrap_or("");
    let recent = sentence
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|s| !s.is_empty())
        .rev()
        .take(4)
        .collect::<Vec<_>>();
    let mut scores = HashMap::<&str, f64>::new();
    let mut matched_words = 0;
    let mut key = String::new();
    for (i, word) in recent.into_iter().enumerate() {
        key = if i == 0 {
            word.to_owned()
        } else {
            format!("{word} {key}")
        };
        if let Ok(index) = PREDICT.binary_search_by_key(&key.as_str(), |(k, _)| *k) {
            matched_words = i + 1;
            let mut cs = [("", 0u32); 6];
            for (slot, entry) in cs.iter_mut().zip(PREDICT[index].1.split_ascii_whitespace()) {
                if let Some((w, n)) = entry.split_once(':') {
                    *slot = (w, n.parse().unwrap_or(0));
                }
            }
            let mass = cs.iter().map(|(_, c)| c).sum::<u32>() as f64;
            for (w, n) in cs.into_iter().take_while(|(_, n)| *n != 0) {
                *scores.entry(w).or_default() += [1., 3., 8., 18.][i] * n as f64 / (mass + 3.);
            }
        }
    }
    // Service-dialog unigram frequencies skew toward orders and reservations.
    // Without a matching phrase, prefer the general English distribution.
    if matched_words <= 1 {
        let (_, last) = history(context);
        if let Some(general) = NEXT.get(last.as_str()) {
            let mut out: Vec<_> = general.iter().take(3).map(|(w, _)| *w).collect();
            for w in ["i", "the", "you"] {
                if out.len() == 3 {
                    break;
                }
                if !out.contains(&w) {
                    out.push(w);
                }
            }
            return out;
        }
    }
    let mut result: Vec<_> = scores.into_iter().collect();
    result.sort_unstable_by(|a, b| b.1.total_cmp(&a.1).then_with(|| a.0.cmp(b.0)));
    let mut out: Vec<_> = result.into_iter().take(3).map(|(w, _)| w).collect();
    for w in ["i", "the", "you"] {
        if out.len() == 3 {
            break;
        }
        if !out.contains(&w) {
            out.push(w);
        }
    }
    out
}
// Editorial fallback for frequent letter typos. Apostrophe placement is learned.
fn conventional(w: &str) -> Option<&'static str> {
    Some(match w {
        "teh" => "the",
        "thier" => "their",
        "wierd" => "weird",
        "becuase" => "because",
        "recieve" => "receive",
        "definately" | "definatly" => "definitely",
        "adress" => "address",
        "i" => "I",
        _ => return contractions::conventional(w),
    })
}
// Find words with two omitted letters, or one omission plus one neighboring
// key slip, when the one-edit search failed. Only a small prefix bucket is read.
static PREFIX_WORDS: LazyLock<HashMap<[u8; 2], Vec<&str>>> = LazyLock::new(|| {
    let mut buckets = HashMap::new();
    for &word in WORDS.keys() {
        let b = word.as_bytes();
        if b.len() >= 6 && b.is_ascii() {
            buckets
                .entry([b[0], b[1]])
                .or_insert_with(Vec::new)
                .push(word);
        }
    }
    buckets
});

fn adjacent(a: u8, b: u8, neighbors: &[u32]) -> bool {
    a.is_ascii_lowercase()
        && b.is_ascii_lowercase()
        && neighbors
            .get((a - b'a') as usize)
            .is_some_and(|mask| mask & (1 << (b - b'a')) != 0)
}

fn omission_match(typed: &[u8], target: &[u8], edits: u8, neighbors: &[u32]) -> bool {
    if typed == target {
        return true;
    }
    if edits == 0 || target.len() < typed.len() || target.len() - typed.len() > edits as usize {
        return false;
    }
    if typed.is_empty() {
        return true;
    }
    if typed[0] == target[0] {
        return omission_match(&typed[1..], &target[1..], edits, neighbors);
    }
    (adjacent(typed[0], target[0], neighbors)
        && omission_match(&typed[1..], &target[1..], edits - 1, neighbors))
        || omission_match(typed, &target[1..], edits - 1, neighbors)
}

fn omitted_candidates(typed: &[u8], neighbors: &[u32]) -> (bool, Vec<&'static str>) {
    if typed.len() < 6 {
        return (false, vec![]);
    }
    let bucket = PREFIX_WORDS.get(&[typed[0], typed[1]]);
    let mut hits: Vec<_> = bucket
        .into_iter()
        .flatten()
        .copied()
        .filter(|word| {
            word.len() > typed.len()
                && word.len() <= typed.len() + 2
                && word.as_bytes().last() == typed.last()
                && omission_match(typed, word.as_bytes(), 2, neighbors)
        })
        .collect();
    hits.sort_unstable_by_key(|word| (std::cmp::Reverse(WORDS[*word]), *word));
    let strong = hits.len() == 1 && WORDS[hits[0]] >= 15;
    hits.truncate(3);
    (strong, hits)
}

// A short fragment by itself is ambiguous. Require both a close physical edit
// and a phrase independently observed in the corpus before committing it.
fn short_phrase_repair(typed: &[u8], context: &str, neighbors: &[u32]) -> Option<&'static str> {
    let index = PREDICT.binary_search_by_key(&context, |(k, _)| *k).ok()?;
    let mut counts = PREDICT[index]
        .1
        .split_ascii_whitespace()
        .filter_map(|entry| {
            let (word, count) = entry.split_once(':')?;
            Some((word, count.parse::<u32>().ok()?))
        });
    if typed.len() == 2 {
        let (best, count) = counts.next()?;
        let runner = counts.next().map_or(0, |entry| entry.1);
        return (count >= 5
            && count >= runner * 3
            && best.len() == 3
            && omission_match(typed, best.as_bytes(), 1, neighbors))
        .then_some(best);
    }
    let mut matches = counts.filter(|(word, count)| {
        *count >= 10
            && word.len() == 4
            && DISPLAY.contains(word)
            && omission_match(typed, word.as_bytes(), 2, neighbors)
    });
    let (best, _) = matches.next()?;
    matches.next().is_none().then_some(best)
}

// Pair counts come from the same public training split as the lexical tables.
// Keep one sorted index, shared by word separation and touch-error ranking.
static PAIRS: LazyLock<Vec<(&str, u32)>> = LazyLock::new(|| {
    include_str!("../model/edit-phrases.tsv")
        .lines()
        .filter_map(|line| {
            let (pair, count) = line.split_once('\t')?;
            Some((pair, count.parse().ok()?))
        })
        .collect()
});
fn pair_count(left: &str, right: &str) -> u32 {
    let key = format!("{left} {right}");
    PAIRS
        .binary_search_by_key(&key.as_str(), |row| row.0)
        .map_or(0, |i| PAIRS[i].1)
}

// Distinct clean training messages containing a word or adjacent pair. Use
// these alongside the less templated corpus; neither includes held-out texts.
static BOUNDARIES: LazyLock<Vec<(&str, u32)>> = LazyLock::new(|| {
    include_str!("../model/boundary-counts.tsv")
        .lines()
        .map(|l| {
            let (term, n) = l.split_once('\t').expect("boundary table row");
            (term, n.parse().expect("boundary count"))
        })
        .collect()
});
fn observations(term: &str) -> u32 {
    BOUNDARIES
        .binary_search_by_key(&term, |r| r.0)
        .map_or(0, |i| BOUNDARIES[i].1)
}
fn evidence(a: &str, b: &str) -> u32 {
    observations(&format!("{a} {b}")).max(pair_count(a, b))
}

// Exact single-word entries from the system wordlist. Keep the shipping
// subset to spellings that could plausibly be mistaken for two known words.
static WHOLE_COMPOUNDS: LazyLock<Vec<&str>> = LazyLock::new(|| {
    include_str!("../model/whole-compounds.txt")
        .lines()
        .collect()
});
fn whole_compound(word: &str) -> bool {
    let contains = |s: &str| WHOLE_COMPOUNDS.binary_search(&s).is_ok();
    contains(word)
        || word.strip_suffix('s').is_some_and(contains)
        || word.strip_suffix("es").is_some_and(contains)
}
/// # Safety
/// word must point to a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn mb_whole_compound_v1(word: *const c_char) -> i32 {
    if word.is_null() {
        return 0;
    }
    i32::from(
        unsafe { CStr::from_ptr(word) }
            .to_str()
            .is_ok_and(|s| s.len() <= 32 && whole_compound(s)),
    )
}

// UIKit supplies dictionary segmentation candidates that the finite n-gram
// tables may never have seen. Corroborate the boundary, not just the two words.
fn supports_native_split(prev: &str, word: &str, candidate: &str, rank: u32) -> bool {
    if !(4..=32).contains(&word.len())
        || !word.bytes().all(|c| c.is_ascii_lowercase())
        || WORDS.contains_key(word)
        || observations(word) > 0
        || rank > 3
    {
        return false;
    }
    let Some((a, b)) = candidate.split_once(' ') else {
        return false;
    };
    if a.is_empty()
        || b.is_empty()
        || !a.bytes().chain(b.bytes()).all(|c| c.is_ascii_lowercase())
        || a.len() + b.len() != word.len()
        || !word.starts_with(a)
        || !word.ends_with(b)
        || (a.len() == 1 && !matches!(a, "a" | "i"))
        || (b.len() == 1 && !matches!(b, "a" | "i"))
    {
        return false;
    }
    let freq = |s: &str| WORDS.get(s).copied().unwrap_or(0).max(observations(s));
    let inner = evidence(a, b);
    let lead = evidence(prev, a);
    // An unknown compound can also have a plausible spaced dictionary guess.
    // Without repeated pair evidence, require a grammatical boundary rather
    // than accepting two dictionary nouns merely because the string is long.
    let grammar_word = |s: &str| {
        matches!(
            s,
            "a" | "an"
                | "the"
                | "my"
                | "your"
                | "his"
                | "her"
                | "our"
                | "their"
                | "of"
                | "in"
                | "at"
                | "with"
                | "for"
                | "by"
                | "from"
                | "to"
                | "and"
                | "or"
                | "but"
                | "when"
                | "if"
                | "than"
                | "that"
                | "this"
                | "these"
                | "those"
                | "is"
                | "are"
                | "was"
                | "were"
                | "be"
                | "been"
                | "has"
                | "have"
                | "had"
                | "he"
                | "she"
                | "they"
                | "we"
                | "you"
                | "it"
                | "i"
                | "us"
                | "them"
                | "me"
                | "will"
                | "can"
                | "should"
                | "would"
                | "might"
                | "could"
                | "not"
                | "any"
                | "some"
                | "before"
                | "after"
                | "until"
        )
    };
    let inflected = |s: &str| {
        (s.len() >= 5 && (s.ends_with("ed") || s.ends_with("ing")))
            || (s.len() >= 5 && s.ends_with('s') && !s.ends_with("ss"))
    };
    let grammatical = grammar_word(a)
        || grammar_word(b)
        || inflected(a)
        || inflected(b)
        || (evidence("to", a) >= 4 && (evidence("can", a) >= 2 || evidence("will", a) >= 2));
    if inner < 6 && !grammatical {
        return false;
    }
    if word.len() == 4 && lead < 2 {
        return false;
    }
    if inner >= 6 || (inner >= 2 && lead >= 2) {
        return true;
    }
    // A native first-choice exact split plus two substantial known parts also
    // covers new combinations. Short, lower-ranked parts need left evidence.
    if freq(a) == 0 || freq(b) == 0 {
        return false;
    }
    (rank <= 1
        && word.len() >= 7
        && a.len().min(b.len()) >= 2
        && (lead >= 2 || (a.len().min(b.len()) >= 3 && (rank == 0 || word.len() >= 9))))
        || (rank <= 2 && word.len() >= 5 && lead >= 3 && freq(b) >= 5)
}

/// # Safety
/// All inputs must be NUL-terminated strings valid for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn mb_supports_split_v1(
    previous: *const c_char,
    word: *const c_char,
    candidate: *const c_char,
    rank: u32,
) -> i32 {
    if previous.is_null() || word.is_null() || candidate.is_null() {
        return 0;
    }
    let (Ok(prev), Ok(w), Ok(c)) = (
        unsafe { CStr::from_ptr(previous) }.to_str(),
        unsafe { CStr::from_ptr(word) }.to_str(),
        unsafe { CStr::from_ptr(candidate) }.to_str(),
    ) else {
        return 0;
    };
    i32::from(prev.len() <= 80 && c.len() <= 33 && supports_native_split(prev, w, c, rank))
}

fn boundary_candidate(prev: &str, word: &str) -> Option<(i32, String)> {
    if !(5..=32).contains(&word.len())
        || !word.bytes().all(|b| b.is_ascii_lowercase())
        || WORDS.contains_key(word)
        || observations(word) > 0
    {
        return None;
    }
    let mut candidates = Vec::new();
    for i in 2..word.len() - 1 {
        let (a, b) = word.split_at(i);
        let freq = |s: &str| WORDS.get(s).copied().unwrap_or(0).max(observations(s));
        if freq(a) < 4 || freq(b) < 4 {
            continue;
        }
        let lead = evidence(prev, a);
        let inner = evidence(a, b);
        let immediate = inner >= 4 && (lead >= 2 || inner >= 15);
        // A sentence can contain a new combination, e.g. "the kids in ...".
        // A trailing preposition still needs a compatible phrase to its right.
        let review = matches!(
            b,
            "in" | "on" | "at" | "to" | "of" | "for" | "from" | "with"
        ) && (lead >= 2
            || (matches!(
                prev,
                "the" | "my" | "your" | "our" | "their" | "his" | "her"
            ) && a.len() >= 3
                && a.ends_with('s')
                && freq(a) >= 6));
        if immediate || review {
            candidates.push((
                inner.min(40) * 2 + lead.min(40),
                if immediate { 1 } else { 2 },
                a,
                b,
            ));
        }
    }
    candidates.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    let &(s, stage, a, b) = candidates.first()?;
    if candidates.get(1).is_some_and(|next| s <= next.0 * 2) {
        return None;
    }
    Some((stage, format!("{a} {b}")))
}

/// # Safety
/// Both inputs must point to UTF-8 C strings; out must hold capacity writable bytes.
#[no_mangle]
pub unsafe extern "C" fn mb_trained_split_v1(
    previous: *const c_char,
    word: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if previous.is_null() || word.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    let (Ok(p), Ok(w)) = (
        unsafe { CStr::from_ptr(previous) }.to_str(),
        unsafe { CStr::from_ptr(word) }.to_str(),
    ) else {
        return -1;
    };
    if p.len() > 80 {
        return 0;
    }
    let Some((_, form)) = context21::split(p, w) else {
        return 0;
    };
    if form.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(form.as_ptr(), out.cast(), form.len());
        *out.add(form.len()) = 0;
    }
    1
}

/// # Safety
/// Inputs must be valid NUL-terminated UTF-8; out must hold capacity writable bytes.
/// 1: strongly attested split; 2: wait for right context; 0: keep incumbent policy.
#[no_mangle]
pub unsafe extern "C" fn mb_boundary_v1(
    previous: *const c_char,
    word: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if previous.is_null() || word.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    unsafe {
        *out = 0;
    }
    let (Ok(prev), Ok(w)) = (
        unsafe { CStr::from_ptr(previous) }.to_str(),
        unsafe { CStr::from_ptr(word) }.to_str(),
    ) else {
        return -1;
    };
    if prev.len() > 80 {
        return -1;
    }
    let Some((stage, result)) = boundary_candidate(prev, w) else {
        return 0;
    };
    if result.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(result.as_ptr(), out.cast(), result.len());
        *out.add(result.len()) = 0;
    }
    stage
}
/// # Safety
/// Inputs must be valid NUL-terminated strings. No text is retained.
#[no_mangle]
pub unsafe extern "C" fn mb_pair_support_v1(left: *const c_char, right: *const c_char) -> u32 {
    if left.is_null() || right.is_null() {
        return 0;
    }
    let (Ok(a), Ok(b)) = (
        unsafe { CStr::from_ptr(left) }.to_str(),
        unsafe { CStr::from_ptr(right) }.to_str(),
    ) else {
        return 0;
    };
    if a.len() > 80 || b.len() > 80 {
        return 0;
    }
    evidence(a, b)
}

fn separate_words(word: &str, previous: &str) -> Option<String> {
    if word.len() < 5 || WORDS.contains_key(word) {
        return None;
    }
    let mut candidates = vec![];
    for i in 1..word.len() {
        let (a, b) = word.split_at(i);
        let (Some(&fa), Some(&fb)) = (WORDS.get(a), WORDS.get(b)) else {
            continue;
        };
        if (a.len() == 1 && a != "a" && a != "i") || (b.len() == 1 && b != "a" && b != "i") {
            continue;
        }
        let together = pair_count(a, b);
        let lead = pair_count(previous, a);
        if (together >= 2 && fa.min(fb) >= 4)
            || (lead >= 3 && fa.min(fb) >= 12 && a.len().min(b.len()) >= 2)
        {
            candidates.push((together.saturating_mul(2) + lead.min(30), a, b));
        }
    }
    candidates.sort_unstable_by(|a, b| b.0.cmp(&a.0));
    let &(best, a, b) = candidates.first()?;
    if candidates.get(1).is_some_and(|other| best < 3 * other.0) {
        return None;
    }
    Some(format!("{a} {b}"))
}

// Test structured two-touch errors without expanding the alphabet twice at
// every position. Only words in the same length bucket can match either edit.
static LENGTHS: LazyLock<Vec<Vec<&str>>> = LazyLock::new(|| {
    let mut buckets = vec![vec![]; 17];
    for (&word, &count) in WORDS.iter() {
        if (4..buckets.len()).contains(&word.len())
            && count >= 3
            && word.bytes().all(|c| c.is_ascii_lowercase())
        {
            buckets[word.len()].push(word);
        }
    }
    buckets
});
fn touch_match(typed: &[u8], target: &[u8], masks: &[u32]) -> bool {
    if typed.len() == target.len() {
        let mut edits = 0;
        for (&a, &b) in typed.iter().zip(target) {
            if a != b {
                if edits == 2 || !adjacent(a, b, masks) {
                    return false;
                }
                edits += 1;
            }
        }
        return edits == 2;
    }
    // Delete one missing character from the candidate and look for precisely
    // one adjacent transposition among the remaining letters.
    if typed.len() + 1 != target.len() || typed.len() < 4 {
        return false;
    }
    for skip in 0..target.len() {
        let at = |i: usize| target[i + usize::from(i >= skip)];
        let Some(i) = (0..typed.len()).find(|&i| typed[i] != at(i)) else {
            continue;
        };
        if i + 1 < typed.len()
            && typed[i] == at(i + 1)
            && typed[i + 1] == at(i)
            && (i + 2..typed.len()).all(|j| typed[j] == at(j))
        {
            return true;
        }
    }
    false
}
fn touch_repair(word: &str, previous: &str, masks: &[u32]) -> Option<&'static str> {
    if !(4..=15).contains(&word.len()) || masks.len() != 26 {
        return None;
    }
    let mut hits = vec![];
    for &w in LENGTHS[word.len()].iter().chain(&LENGTHS[word.len() + 1]) {
        if touch_match(word.as_bytes(), w.as_bytes(), masks) {
            let count = pair_count(previous, w);
            let score = (WORDS[w] as f64).ln() + 2. * (1. + count as f64).ln();
            hits.push((score, count, w));
        }
    }
    hits.sort_unstable_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.2.cmp(b.2)));
    let &(score, count, best) = hits.first()?;
    let margin = hits.get(1).map_or(f64::INFINITY, |x| score - x.0);
    // For short words or damaged endings, two close keys alone are weak
    // evidence. Require the local phrase to have been independently observed.
    let phrase = format!("{previous} {best}");
    let familiar_phrase = count >= 2
        || PREDICT
            .binary_search_by_key(&phrase.as_str(), |r| r.0)
            .is_ok();
    let same_edges = best.as_bytes().first() == word.as_bytes().first()
        && best.as_bytes().last() == word.as_bytes().last();
    let corroborated = if word.len() == 4 {
        familiar_phrase
            && WORDS[best] >= 80
            && margin >= 4.5
            && (same_edges
                || (word.as_bytes()[1..3] == best.as_bytes()[1..3] && WORDS[best] >= 500))
    } else {
        familiar_phrase || (same_edges && WORDS[best] >= 16 && margin >= 3.)
    };
    (corroborated && margin >= 2.3).then_some(best)
}

fn rank(context: &str, word: &str, neighbors: &[u32]) -> (bool, Vec<&'static str>) {
    if word.is_empty() {
        return (false, next_words(context));
    }
    let h = history(context);
    if let Some(w) = conventional(word) {
        return (true, vec![w]);
    }
    let b = word.as_bytes();
    if (2..=3).contains(&b.len()) && !WORDS.contains_key(word) {
        if let Some(candidate) = short_phrase_repair(b, &h.0, neighbors) {
            return (true, vec![candidate]);
        }
    }
    if !(3..=32).contains(&b.len())
        || !b.iter().all(u8::is_ascii_lowercase)
        || WORDS.contains_key(word)
    {
        return (false, vec![]);
    }
    // Score close substitutions against the full phrase table as well as unigram
    // frequency. For example "know how" provides evidence for a short G/H slip.
    let context_predictions = next_words(context);
    let mut scores: HashMap<&str, (f64, bool)> = HashMap::new();
    let mut offer = |bytes: &[u8], edit_prior: f64| {
        let Ok(s) = std::str::from_utf8(bytes) else {
            return;
        };
        let Some((&w, &count)) = WORDS.get_key_value(s) else {
            return;
        };
        let ctx = [&h.0, &h.1]
            .into_iter()
            .zip([1.0, 0.5])
            .filter_map(|(k, scale)| {
                NEXT.get(k.as_str())?
                    .iter()
                    .find(|(s, _)| *s == w)
                    .map(|(_, n)| scale * (1.0 + *n as f64).ln())
            })
            .fold(0.0_f64, f64::max);
        let phrase_bonus = if !h.1.is_empty() && context_predictions.contains(&w) {
            1.15
        } else {
            0.0
        };
        let score = (1.0 + count as f64).ln() + edit_prior + ctx + phrase_bonus;
        // A globally frequent three-letter word should not swallow an ambiguous
        // four-letter typo. Leave that choice in the suggestion strip.
        let confident = count >= 8 && DISPLAY.contains(w) && !(b.len() == 4 && w.len() == 3);
        let x = scores.entry(w).or_insert((score, confident));
        x.0 = x.0.max(score);
    };
    let mut v = b.to_vec();
    for i in 0..b.len() {
        v.remove(i);
        offer(&v, if i > 0 && b[i - 1] == b[i] { 2.0 } else { 0.2 });
        v.insert(i, b[i]);
        if i + 1 < b.len() && b[i] != b[i + 1] {
            v.swap(i, i + 1);
            offer(&v, 2.2);
            v.swap(i, i + 1);
        }
        for c in b'a'..=b'z' {
            v[i] = c;
            let adjacent = neighbors
                .get(usize::from(b[i] - b'a'))
                .is_some_and(|m| m & (1 << (c - b'a')) != 0);
            offer(&v, if adjacent { 1.0 } else { 0.0 });
        }
        v[i] = b[i];
    }
    for i in 0..=b.len() {
        v.insert(i, b'a');
        for c in b'a'..=b'z' {
            v[i] = c;
            offer(&v, 0.4);
        }
        v.remove(i);
    }
    if scores.is_empty() {
        return omitted_candidates(b, neighbors);
    }
    let mut ranked: Vec<_> = scores.into_iter().collect();
    ranked.sort_unstable_by(|a, b| b.1 .0.total_cmp(&a.1 .0).then_with(|| a.0.cmp(b.0)));
    let automatic = ranked.first().is_some_and(|(_, (best, allowed))| {
        *allowed
            && b.len() >= 4
            && *best >= 4.0
            && best - ranked.get(1).map_or(1.0, |x| x.1 .0) >= 1.8
    });
    (automatic, ranked.into_iter().take(3).map(|x| x.0).collect())
}

/// General-English occurrence count used when combining independent spelling guesses.
/// # Safety
/// A non-null pointer must refer to a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn mb_frequency_v1(word: *const c_char) -> u32 {
    if word.is_null() {
        return 0;
    }
    std::panic::catch_unwind(|| {
        unsafe { CStr::from_ptr(word) }
            .to_str()
            .ok()
            .and_then(|text| WORDS.get(text).copied())
            .unwrap_or(0)
    })
    .unwrap_or(0)
}

/// # Safety
/// Inputs must be valid NUL-terminated strings; out points to capacity writable bytes.
/// Caller-owned memory is never retained. Unexpected panics produce an error.
#[no_mangle]
pub unsafe extern "C" fn mb_rank_v1(
    context: *const c_char,
    word: *const c_char,
    neighbor_masks: *const u32,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if context.is_null() || word.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    unsafe {
        *out = 0;
    }
    std::panic::catch_unwind(|| {
        let (Ok(ctx), Ok(w)) = (
            unsafe { CStr::from_ptr(context) }.to_str(),
            unsafe { CStr::from_ptr(word) }.to_str(),
        ) else {
            return -1;
        };
        if ctx.len() > 2048 || w.len() > 160 {
            return -1;
        }
        let masks = if neighbor_masks.is_null() {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(neighbor_masks, 26) }
        };
        let (accept, words) = if let Ok(i) = PAIRED_EDITS.binary_search_by_key(&w, |r| r.0) {
            (true, vec![PAIRED_EDITS[i].1])
        } else {
            rank(ctx, w, masks)
        };
        let s = words.join("\t");
        if s.len() >= capacity {
            return -1;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), out.cast(), s.len());
            *out.add(s.len()) = 0;
        }
        i32::from(accept)
    })
    .unwrap_or(-1)
}

/// Additional candidates when word separation or two touch errors explain an unknown token.
/// # Safety
/// Pointers have the same ownership and buffer requirements as mb_rank_v1.
#[no_mangle]
pub unsafe extern "C" fn mb_touch_repair_v1(
    context: *const c_char,
    word: *const c_char,
    neighbor_masks: *const u32,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if context.is_null() || word.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    unsafe {
        *out = 0;
    }
    let (Ok(ctx), Ok(w)) = (
        unsafe { CStr::from_ptr(context) }.to_str(),
        unsafe { CStr::from_ptr(word) }.to_str(),
    ) else {
        return -1;
    };
    let masks = if neighbor_masks.is_null() {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(neighbor_masks, 26) }
    };
    if ctx.len() > 2048 {
        return -1;
    }
    let repairable = (4..=32).contains(&w.len())
        && w.bytes().all(|c| c.is_ascii_lowercase())
        && !WORDS.contains_key(w);
    let repair = if repairable {
        let (_, previous) = history(ctx);
        separate_words(w, &previous)
            .or_else(|| touch_repair(w, &previous, masks).map(str::to_owned))
    } else {
        None
    };
    let Some(repair) = repair else {
        return 0;
    };
    if repair.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(repair.as_ptr(), out.cast(), repair.len());
        *out.add(repair.len()) = 0;
    }
    1
}

/// Write matching context lengths and their next-word counts, one row per suffix.
/// # Safety
/// The caller supplies a NUL-terminated context and an output buffer of capacity bytes.
#[no_mangle]
pub unsafe extern "C" fn mb_phrase_evidence_v1(
    context: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> i32 {
    if context.is_null() || out.is_null() || capacity == 0 {
        return -1;
    }
    unsafe { *out = 0 };
    let Ok(context) = (unsafe { CStr::from_ptr(context) }).to_str() else {
        return -1;
    };
    if context.len() > 2048 {
        return -1;
    }
    let lower = context.to_ascii_lowercase().replace('’', "'");
    let clause = lower
        .trim_end_matches([' ', '\t'])
        .rsplit(['.', '!', '?', '\n', ';', ':'])
        .next()
        .unwrap_or("");
    let words: Vec<_> = clause
        .split(|c: char| !c.is_ascii_alphabetic() && c != '\'')
        .filter(|w| !w.is_empty())
        .collect();
    let mut rows = String::new();
    for n in 1..=words.len().min(4) {
        let key = words[words.len() - n..].join(" ");
        if let Ok(index) = PREDICT.binary_search_by_key(&key.as_str(), |r| r.0) {
            use std::fmt::Write;
            let _ = writeln!(rows, "{n} {}", PREDICT[index].1);
        }
        if let Ok(index) = PAIRED_NEXT.binary_search_by_key(&key.as_str(), |r| r.0) {
            use std::fmt::Write;
            // Negative lengths mark the paired-data source for Swift's mixer.
            let _ = writeln!(rows, "-{n} {}", PAIRED_NEXT[index].1);
        }
    }
    if rows.len() >= capacity {
        return -1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(rows.as_ptr(), out.cast(), rows.len());
        *out.add(rows.len()) = 0;
    }
    rows.len() as i32
}

// Preserve the Swift/C ABI in a statistical-only build.
#[cfg(not(feature = "lm-neural"))]
#[no_mangle]
pub extern "C" fn mb_sentence_scores_v1(
    _: *const c_char,
    _: *const c_char,
    _: *mut f32,
    _: usize,
) -> i32 {
    0
}

#[cfg(not(feature = "lm-neural"))]
#[no_mangle]
pub extern "C" fn mb_refine_v1(
    _: *const c_char,
    _: *const c_char,
    _: *const c_char,
    _: *const c_char,
) -> i32 {
    -1
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn leaves_valid_words_and_ambiguous_short_edits_alone() {
        for w in ["were", "well", "shell", "thme", "café", "🧑🏾‍💻"] {
            assert!(!rank("Please tell ", w, &[]).0, "{w}");
        }
    }
    #[test]
    fn dictionary_and_context_survive_without_geometry() {
        assert_eq!(rank("Come back ", "agian", &[]).1[0], "again");
        assert!(rank("", "dont", &[]).0);
        assert!(rank("I wanted to say thank you so ", "", &[])
            .1
            .contains(&"much"));
        assert_eq!(rank("Previously: ", "", &[]).1, rank("", "", &[]).1);
    }
    #[test]
    fn first_person_casing_is_preserved_by_the_ffi_candidates() {
        for (typed, expected) in [("im", "I'm"), ("ive", "I've"), ("i", "I"), ("i'd", "I'd")] {
            assert_eq!(rank("sorry ", typed, &[]), (true, vec![expected]));
        }
        for w in ["id", "ill", "well", "were"] {
            assert!(!rank("", w, &[]).0);
        }
    }
    #[test]
    fn corroborates_exact_spaces_without_rewriting_literals_or_letters() {
        assert!(supports_native_split("the", "doglaughed", "dog laughed", 0));
        assert!(supports_native_split("the", "thewater", "the water", 1));
        assert!(!supports_native_split("the", "thewater", "the waiter", 0));
        assert!(!supports_native_split("the", "notebook", "note book", 0));
        assert!(!supports_native_split("the", "goon", "go on", 0));
        assert!(!supports_native_split("the", "friends", "friend s", 0));
    }

    #[test]
    fn history_does_not_leak_across_sentences() {
        assert_eq!(next_words("I will pick you. "), next_words(""));
        assert_eq!(
            next_words("One more thing! I'll pick you "),
            next_words("I'll pick you ")
        );
    }
    #[test]
    fn too_small_c_buffer_is_left_empty() {
        let mut out = [42i8; 1];
        let rc = unsafe {
            mb_rank_v1(
                c"".as_ptr(),
                c"dont".as_ptr(),
                std::ptr::null(),
                out.as_mut_ptr(),
                out.len(),
            )
        };
        assert_eq!((rc, out[0]), (-1, 0));
    }
}
