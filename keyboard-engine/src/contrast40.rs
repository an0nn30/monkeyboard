//! Conservative pairwise contextual classifiers trained on both valid meanings.
//! The zero score is the literal; each contrast must clear its own threshold
//! on unseen clean contexts. No raw messages or exact sentence keys are stored.
use std::collections::HashMap;
use std::sync::LazyLock;

const WEIGHTS: &[u8] = include_bytes!("../model/contrast42/weights.bin");
static FEATURES: LazyLock<Vec<&'static str>> = LazyLock::new(|| {
    include_str!("../model/contrast42/features.txt")
        .lines()
        .collect()
});

struct Contrast {
    target: &'static str,
    threshold: i32,
    start: usize,
    length: usize,
}
impl Contrast {
    fn weight(&self, feature: u32) -> i32 {
        let mut lo = self.start;
        let mut hi = lo + self.length;
        while lo < hi {
            let m = (lo + hi) / 2;
            let offset = m * 6;
            let key = u32::from_le_bytes(WEIGHTS[offset..offset + 4].try_into().unwrap());
            match key.cmp(&feature) {
                std::cmp::Ordering::Less => lo = m + 1,
                std::cmp::Ordering::Greater => hi = m,
                std::cmp::Ordering::Equal => {
                    return i16::from_le_bytes(WEIGHTS[offset + 4..offset + 6].try_into().unwrap())
                        as i32
                }
            }
        }
        0
    }
}
pub(super) fn allowed(literal: &str, target: &str) -> bool {
    !include_str!("../model/trust50/suggestion-only.tsv").lines().any(|row|
        row.split_once('\t') == Some((literal, target)))
}
static MODELS: LazyLock<HashMap<&'static str, Vec<Contrast>>> = LazyLock::new(|| {
    let mut models: HashMap<&str, Vec<Contrast>> = HashMap::new();
    for line in include_str!("../model/contrast47/models.tsv").lines() {
        let mut f = line.split('\t');
        let source = f.next().unwrap();
        models.entry(source).or_default().push(Contrast {
            target: f.next().unwrap(),
            threshold: (f.next().unwrap().parse::<f32>().unwrap() * 100.).round() as i32,
            start: f.next().unwrap().parse().unwrap(),
            length: f.next().unwrap().parse().unwrap(),
        });
    }
    models
});

pub(super) fn repair(left: &str, word: &str, right: &str) -> Option<String> {
    let alternatives = MODELS.get(word)?;
    let boundary = ['.', '!', '?', ';', ':', '\n'];
    let segment = |c: char| !c.is_ascii_lowercase() && c != '\'';
    let left = left
        .rsplit(boundary)
        .next()?
        .to_ascii_lowercase()
        .replace('’', "'");
    let right = right
        .split(boundary)
        .next()?
        .to_ascii_lowercase()
        .replace('’', "'");
    let mut prev = left.split(segment).rev().filter(|w| !w.is_empty());
    let mut next = right.split(segment).filter(|w| !w.is_empty());
    let b = prev.next().unwrap_or("^");
    let a = prev.next().unwrap_or("^");
    let d = next.next()?;
    let e = next.next().unwrap_or("?");
    let [ac, bc, dc, ec] = [a, b, d, e].map(|w| {
        super::cloze27::grammar_class(w)
            .map(|c| c.to_string())
            .unwrap_or_else(|| "?".into())
    });
    let mut features = Vec::with_capacity(16);
    for (i, part) in [a, b, d, e, &ac, &bc, &dc, &ec].iter().enumerate() {
        if *part != "?" {
            features.push(format!("{i}:{part}"));
        }
    }
    for (n, (x, y)) in [
        (a, b),
        (b, d),
        (d, e),
        (bc.as_str(), dc.as_str()),
        (b, &dc),
        (&bc, d),
        (&ac, &bc),
        (&dc, &ec),
    ]
    .into_iter()
    .enumerate()
    {
        if x != "?" && y != "?" {
            features.push(format!("{}:{x}/{y}", n + 8));
        }
    }
    let ids: Vec<u32> = features
        .iter()
        .filter_map(|f| FEATURES.binary_search(&f.as_str()).ok().map(|i| i as u32))
        .collect();
    let mut winner = None;
    for model in alternatives {
        let score: i32 = ids.iter().map(|&id| model.weight(id)).sum();
        if score >= model.threshold && allowed(word, model.target) {
            // Margins from distinct classifiers aren't a common probability scale.
            // On competing winners, keep the user's literal.
            if winner.is_some() {
                return None;
            }
            winner = Some(model.target);
        }
    }
    winner.map(str::to_owned)
}
