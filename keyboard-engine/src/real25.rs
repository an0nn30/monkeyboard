//! Rank short, dictionary-valid alternatives with a bidirectional word cloze.
//! A change must beat both the literal and the next best neighboring spelling.
use std::{collections::HashMap, sync::LazyLock};

const DATA: &[u8] = include_bytes!("../model/real25/cloze.bin");
const WIDTH: usize = 40;
const HIDDEN: usize = 120;
const CONTEXT: usize = 5;

struct Matrix {
    weights: &'static [u8],
    scale: Vec<f32>,
    cols: usize,
}
impl Matrix {
    fn load(data: &mut &'static [u8], rows: usize, cols: usize) -> Self {
        let scale = take_floats(data, rows);
        let (weights, rest) = data.split_at(rows * cols);
        *data = rest;
        Self {
            weights,
            scale,
            cols,
        }
    }
    fn row(&self, i: usize) -> &[u8] {
        &self.weights[i * self.cols..(i + 1) * self.cols]
    }
    fn dot(&self, i: usize, x: &[f32]) -> f32 {
        self.row(i)
            .iter()
            .zip(x)
            .map(|(&w, &v)| f32::from(w as i8) * v)
            .sum::<f32>()
            * self.scale[i]
    }
}
fn take_floats(data: &mut &'static [u8], n: usize) -> Vec<f32> {
    let (bytes, rest) = data.split_at(4 * n);
    *data = rest;
    bytes
        .chunks_exact(4)
        .map(|v| f32::from_le_bytes(v.try_into().unwrap()))
        .collect()
}
struct Target {
    word: &'static str,
    neighbors: Vec<usize>,
}
struct Model {
    ids: HashMap<&'static str, usize>,
    target_ids: HashMap<&'static str, usize>,
    targets: Vec<Target>,
    embeddings: Matrix,
    hidden: Matrix,
    output: Matrix,
    hidden_bias: Vec<f32>,
    output_bias: Vec<f32>,
    min_margin: f32,
    min_gap: f32,
}
impl Model {
    fn load() -> Self {
        let ids: HashMap<_, _> = include_str!("../model/real25/vocab.txt")
            .lines()
            .enumerate()
            .map(|(i, w)| (w, i))
            .collect();
        let targets: Vec<_> = include_str!("../model/real25/targets.tsv")
            .lines()
            .map(|s| {
                let mut fields = s.split('\t');
                let word = fields.next().unwrap();
                let _frequency = fields.next();
                let neighbors = fields
                    .next()
                    .unwrap()
                    .split(',')
                    .filter(|s| !s.is_empty())
                    .map(|s| s.parse().unwrap())
                    .collect();
                Target { word, neighbors }
            })
            .collect();
        let target_ids = targets
            .iter()
            .enumerate()
            .map(|(i, t)| (t.word, i))
            .collect();
        let mut policy = include_str!("../model/real25/policy.txt")
            .split_whitespace()
            .map(|s| s.parse::<f32>().unwrap());
        let min_margin = policy.next().unwrap();
        let min_gap = policy.next().unwrap();
        let mut data = DATA;
        for n in [ids.len(), targets.len(), WIDTH, HIDDEN] {
            let (bytes, rest) = data.split_at(4);
            data = rest;
            assert_eq!(u32::from_le_bytes(bytes.try_into().unwrap()) as usize, n);
        }
        let embeddings = Matrix::load(&mut data, ids.len(), WIDTH);
        let hidden = Matrix::load(&mut data, HIDDEN, WIDTH * CONTEXT);
        let output = Matrix::load(&mut data, targets.len(), HIDDEN);
        let hidden_bias = take_floats(&mut data, HIDDEN);
        let output_bias = take_floats(&mut data, targets.len());
        assert!(data.is_empty());
        Self {
            ids,
            target_ids,
            targets,
            embeddings,
            hidden,
            output,
            hidden_bias,
            output_bias,
            min_margin,
            min_gap,
        }
    }
    fn activation(&self, ids: [usize; CONTEXT]) -> [f32; HIDDEN] {
        let mut inputs = [0.; WIDTH * CONTEXT];
        for (dest, i) in inputs.chunks_exact_mut(WIDTH).zip(ids) {
            for (x, &v) in dest.iter_mut().zip(self.embeddings.row(i)) {
                *x = f32::from(v as i8) * self.embeddings.scale[i];
            }
        }
        std::array::from_fn(|j| (self.hidden.dot(j, &inputs) + self.hidden_bias[j]).tanh())
    }
    fn score(&self, id: usize, hidden: &[f32; HIDDEN]) -> f32 {
        self.output.dot(id, hidden) + self.output_bias[id]
    }
}
static MODEL: LazyLock<Model> = LazyLock::new(Model::load);

/// All alternatives are real words separated by a single edit (including
/// transposition). Supply the text on both sides of the marked word.
pub(super) fn repair(left: &str, word: &str, right: &str) -> Option<String> {
    if !(2..=5).contains(&word.len()) || !word.bytes().all(|c| c.is_ascii_lowercase()) {
        return None;
    }
    let id = *MODEL.target_ids.get(word)?;
    let stop = |c| matches!(c, '.' | '?' | '!' | ';' | ':' | '\n');
    let l = left
        .rsplit(stop)
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
        .replace('’', "'");
    let r = right
        .split(stop)
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
        .replace('’', "'");
    let token_delimiter = |c: char| !c.is_ascii_lowercase() && c != '\'';
    let mut left_words = l.split(token_delimiter).filter(|w| !w.is_empty()).rev();
    let mut right_words = r.split(token_delimiter).filter(|w| !w.is_empty());
    let mut ctx = [1, 1, 1, 2, 2];
    for dest in &mut ctx[..3] {
        if let Some(w) = left_words.next() {
            *dest = MODEL.ids.get(w).copied().unwrap_or(0);
        }
    }
    ctx[3] = MODEL.ids.get(right_words.next()?).copied().unwrap_or(0);
    if let Some(w) = right_words.next() {
        ctx[4] = MODEL.ids.get(w).copied().unwrap_or(0);
    }
    if ctx[3] == 0 || (ctx[0] == 0 && ctx[1] == 0) {
        return None;
    }
    let hidden = MODEL.activation(ctx);
    let literal = MODEL.score(id, &hidden);
    let (mut best, mut second, mut chosen) = (literal, f32::NEG_INFINITY, id);
    for &other in &MODEL.targets[id].neighbors {
        let value = MODEL.score(other, &hidden);
        if value > best {
            second = best;
            best = value;
            chosen = other;
        } else {
            second = second.max(value);
        }
    }
    if chosen == id || best - literal < MODEL.min_margin || best - second < MODEL.min_gap {
        return None;
    }
    Some(MODEL.targets[chosen].word.to_owned())
}

#[cfg(test)]
mod tests {
    use super::repair;

    #[test]
    fn cloze_recovers_a_short_real_word_and_keeps_the_matching_literal() {
        assert_eq!(
            repair("what ", "us", " your favorite song").as_deref(),
            Some("is")
        );
        assert_eq!(repair("what ", "is", " your favorite song"), None);
        assert_eq!(
            repair("Can you ", "fine", " anything").as_deref(),
            Some("find")
        );
        assert_eq!(repair("Can you ", "find", " anything"), None);
    }

    #[test]
    fn cloze_needs_a_following_word_in_the_same_sentence() {
        assert_eq!(repair("what ", "us", ""), None);
        assert_eq!(repair("what ", "us", ". Your friend asked"), None);
        assert_eq!(repair("what ", "US", " your friend asked"), None);
    }
}
