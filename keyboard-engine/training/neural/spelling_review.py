"""Fit the leek/leak review head with public checkpoint features and authored examples.

Train only the binary readout. It reads pooled left-context states, the last
observed word embedding, and the final state of the full span. Training,
calibration, and evaluation use separate sentence frames. No personal text.
"""
import itertools
import re
from pathlib import Path

import numpy as np
import torch
from networks import Decoder

base = Path(__file__).resolve().parents[2]
checkpoint = base / "research/decoder15m"
vocab = (checkpoint / "vocab.txt").read_text().splitlines()
ids = {w: i for i, w in enumerate(vocab)}
torch.manual_seed(1301)
torch.set_num_threads(6)
model = Decoder().eval()
model.load_state_dict(torch.load(checkpoint / "decoder.pt", map_location="cpu", weights_only=True))

# Lefts are grouped by what the writer has made explicit so far. Each right
# group occurs with multiple lefts, including conflicting and ambiguous ones.
ordinary = ["", "a", "the", "one", "we have a", "i noticed a", "she found a", "you have a",
    "there's a", "could this be a", "i wonder if there is a", "we noticed a",
    "they mentioned the", "they just found a", "have you seen a", "we saw this",
    "could there be a", "maybe there is a", "i think there is a", "there was a",
    "they told us there is a", "she says there's another", "we have an unexpected",
    "looks as though there is a", "the problem might be a", "someone noticed one",
    "yesterday he heard about a", "did anyone notice the", "we can see a", "i see a",
    "another possible", "what looks like a", "isn't there a", "there is a small",
    "i just saw a", "there seems to be a", "the photograph shows a", "she pointed out the",
]
repair = [
    "we have to repair the", "the engineer checked for a", "they tried to stop the",
    "we still haven't fixed the", "the technician tested for a", "can you seal the",
    "we detected a water", "it smells like a gas", "they traced the oil",
    "the pipe has a", "the roof has another", "the water tank developed a",
    "the mechanic suspects a", "can you patch this", "was the slow", "they repaired a",
]
food = [
    "slice the", "he dropped the", "she was washing a", "rinse every", "i left a fresh",
    "there's a green", "i need one more", "the farmer planted a", "could you move the",
    "we are growing a", "he was cutting a", "we bought a", "eat the", "grate the",
    "i put the sliced", "she cooked the", "they washed the", "i lost my last",
    "i store the", "i was peeling a", "i stashed the", "he set the", "i dropped my",
    "she placed a", "i found a wilted", "my grandmother chopped a", "we hid the",
    "the cook rinsed a", "there's a plastic", "the picture of a", "they named it",
]
# Local evidence is most helpful when the object itself is known. Unknown
# fixture/food names are kept ambiguous unless there is evidence on the left.
fixtures = "sink pipe tank drain toilet roof radiator shower ceiling tub basin engine hose tap".split()
food_items = "soup salad stew basket oven pot fridge pan garden recipe sandwich broth curry pie".split()
preps = ["beneath", "inside", "under", "near", "around", "below", "behind", "in", "by"]
articles = ["the", "our", "that", "my"]
plumbing = [f"{prep} {det} {obj}" for prep, det, obj in itertools.product(preps, articles, fixtures)]
cooking = [f"{prep} {det} {obj}" for prep, det, obj in itertools.product(preps, articles, food_items)]
generic = ["this afternoon", "last year", "really quickly", "on video", "on the table",
           "several times", "where we live", "over there", "again today", "is still there",
           "on her phone", "for now", "at his house", "right there", "when he returned"]
food += ["we tossed a", "don't throw the", "someone hid an enormous", "they misplaced the",
         "she forgot a", "the chef saved a", "they kept the", "she balanced a", "we rested a",
         "we marked the", "the shop delivered a", "she boiled the", "the kids want a",
         "we lost a raw", "she drew a", "you rinsed that", "there is a fresh", "we propped the"]
meta = ["the nickname is", "the word was", "spell the word", "i meant to type", "we call it", "her code is"]
# Build 13 missed reports by unfamiliar subjects and by owners ("her bathtub").
# Vary the subject, verb, possessive and noun independently. A report alone is
# intentionally inconclusive. Observing vegetables near plumbing is a hard negative.
subjects = ["the resident", "my cousin", "our landlord", "maintenance", "the building manager",
            "my flatmate", "someone upstairs", "our inspector", "a resident", "the owner", "we",
            "the last visitor", "the night crew", "an employee", "the family downstairs", "i", "he", "she", "jordan", "sam"]
actions = ["reported", "discovered", "noticed", "mentioned", "found", "saw", "spotted",
           "documented", "photographed", "suspected", "was looking for", "called about", "complained of"]
reporting = [f"{s} {v} {d}" for s, v, d in itertools.product(subjects, actions, ["a", "the", "another", "a small", "a second", "one more"])]
strong = ["i plugged the", "we had to fix a", "he wants to patch a", "our mechanic repaired the",
          "we suspect another gas", "they detected an oil", "please seal that", "the plumber stopped a",
          "the car has a coolant", "we need to trace this water", "we repaired our roof",
          "she patched the", "we finally fixed that", "did you locate the gas", "the pipe sprang a"]
weather = ["after the storm", "after rain", "during the rain", "when it rains", "following heavy rainfall"]
claims = ["for the insurance claim", "for my insurer", "for insurance", "for the claim"]
places = ["around", "beneath", "above", "behind", "inside", "through", "under", "along", "below", "from",
          "beside", "right behind", "somewhere in", "next to"]
articles14 = ["the", "a", "our", "her", "his", "their", "that", "your", "my"]
# Share representations for fixture variants outside the checkpoint vocabulary.
# These substitutions are local to the pair review.
aliases = {"boiler": "heating", "heater": "heating", "tub": "basin", "bathtub": "basin",
           "hose": "pipe", "hoses": "pipe", "faucet": "tap", "pipes": "pipe", "sinks": "sink",
           "insurer": "insurance", "rainfall": "rain"}
locations = fixtures + ["heating", "valve", "basin", "attic", "boat", "cellar", "boiler", "bathtub", "hose"]
places14 = [f"{v} {d} {o}" for v, d, o in itertools.product(places, articles14, locations)]
neutral_food = ["in the fridge", "on special", "for lunch", "in our basket", "in my soup",
                "for the stew", "on sale", "for a recipe", "at the store", "in my salad"]
handling = ["he hid the", "we placed the", "she rinsed the", "they were slicing a", "he carried a",
            "our groceries included a", "someone dropped a", "someone bought a", "the toy is a",
            "i lost the vegetable", "the market sells a", "the fridge has a", "i kept the last"]
rng = np.random.default_rng(1301)

def sentence_ids(s):
    return [ids.get(aliases.get(w, w), 0) for w in re.findall(r"[a-z]+(?:'[a-z]+)*", s.lower().replace("there's", "there is"))]

def context_ids(left, right):
    # The base decoder does not represent leek. Encode the same neutral
    # marker for either spelling so the head must distinguish the context.
    marker = ids["leak"]
    l = ([1] + sentence_ids(left))[-26:]
    r = sentence_ids(right)[:5]
    # Pool the actual left words rather than the article immediately before
    # the target; take the continuation features from the full sentence.
    return [l, r, l + [marker] + r]

def generate(lefts, rights, label, n, shorten=False):
    out = []
    for _ in range(n):
        l, r = rng.choice(lefts), rng.choice(rights)
        ws = r.split()
        if shorten:
            ws = ws[:rng.integers(1, len(ws) + 1)]
        out.append((str(l), " ".join(ws), label))
    return out

train = (generate(ordinary, plumbing, 1, 1700) + generate(repair, plumbing, 1, 650)
         + generate(repair, generic, 1, 450, True) + generate(food, plumbing, 0, 2200)
         + generate(food + ordinary, cooking + generic, 0, 2300, True)
         + generate(meta, plumbing + generic, 0, 550, True)
         + generate(ordinary, generic + [s.rsplit(" ", 1)[0] for s in plumbing], 0, 1000, True))
train += (generate(reporting, places14, 1, 6500) + generate(ordinary + repair, places14, 1, 4000)
          + generate(strong, generic + weather + claims + places14, 1, 1800)
          + generate(repair + reporting, weather + claims, 1, 2200)
          + generate(food + handling + meta, places14 + weather + claims, 0, 7400)
          + generate(reporting + ordinary, neutral_food + generic, 0, 4500)
          + generate(reporting, [s.rsplit(" ", 1)[0] for s in places14], 0, 2200, True))
# Mix several forms of the same repair request with time phrases. The same
# time phrases paired with observation or handling alone do not imply damage.
repair_actions = [
    f"{subject} {verb} {obj}" for subject, verb, obj in itertools.product(
        ["they", "we", "she", "the technician", "he already", "my friend"],
        ["fixed", "repaired", "patched", "plugged", "sealed"], ["a", "the", "that"])
] + [
    f"{start} {verb} {obj}" for start, verb, obj in itertools.product(
        ["can they", "will you", "did he", "did anyone", "we have to", "please"],
        ["fix", "repair", "patch", "seal"], ["this", "a", "that", "the"])
]
time_phrases = ["late last night", "before the weekend", "earlier this week", "yet this month",
                "before it grew", "again on Tuesday", "just in time", "in the morning", "by next week"]
train += (generate(repair_actions, time_phrases + generic, 1, 4800)
          + generate(reporting + ordinary + food, time_phrases + generic, 0, 2400)
          + generate(repair_actions, neutral_food + cooking, 0, 1000))
# Do not teach a meaning for an unknown right-hand noun from the sentence frame.
report_frames = set(ordinary + reporting)

def usable(row):
    return not (row[2] == 1 and row[0] in report_frames and sentence_ids(row[1])[-1] == 0)

train = sorted(set(row for row in train if usable(row)))

@torch.no_grad()
def features(rows):
    seqs = [context_ids(l, r) for l, r, _ in rows]
    unique = sorted({tuple(full) for _, _, full in seqs}, key=lambda s: (len(s), s))
    states = {}
    for i in range(0, len(unique), 120):
        batch = unique[i:i+120]
        length = max(map(len, batch))
        x = torch.tensor([list(s) + [0]*(length-len(s)) for s in batch])
        h = model.emb(x) + model.pos(torch.arange(length))[None]
        h = model.norm(model.layers(h)).float()
        for j, s in enumerate(batch):
            states[s] = h[j, :len(s)].clone()
    articles = {ids[w] for w in ("a", "an", "the", "my", "our", "this", "that", "one", "another")}
    def pool(l, r, full):
        h = states[tuple(full)]
        content = [i for i, token in enumerate(l) if token not in articles and token > 1][-6:]
        left = h[content].mean(0) if content else h[0]
        return torch.cat((left, model.emb.weight[r[-1]], h[-1]))
    return torch.stack([pool(*triple) for triple in seqs])

def fit(rows):
    x = features(rows)
    y = torch.tensor([y for _, _, y in rows], dtype=torch.float32)
    weight = torch.zeros(x.shape[1], requires_grad=True)
    bias = torch.zeros(1, requires_grad=True)
    opt = torch.optim.LBFGS([weight, bias], max_iter=110, line_search_fn="strong_wolfe")
    def closure():
        opt.zero_grad()
        loss = torch.nn.functional.binary_cross_entropy_with_logits(x @ weight + bias, y) + 0.001 * weight.square().sum()
        loss.backward()
        return loss
    opt.step(closure)
    return weight.detach(), bias.detach()

weights, bias = fit(train)
# Challenge controls include a vegetable being moved/washed near plumbing.
calibration = [
    ("there is a", "under the sink", 1), ("do you see a", "above the tank", 1),
    ("apparently there's a", "in the pipe", 1), ("please fix that", "by tomorrow", 1),
    ("there's a", "in the soup", 0), ("i tossed the", "down the sink", 0),
    ("they left the", "under the sink", 0), ("i rinsed my", "near the drain", 0),
    ("i saw the", "in my bag", 0), ("my neighbor planted one", "beside the pipe", 0),
    ("the answer was", "under the sink", 0), ("is that a", "under the", 0),
    ("i spotted one", "under", 0), ("i threw a rotten", "in the toilet", 0),
    ("he hid a", "behind a pipe", 0), ("she tucked the", "under the sink", 0),
]
scores = (features(calibration) @ weights + bias).tolist()
for row, score in zip(calibration, scores):
    print(row, round(score, 3))
print(f"{len(train)} training contexts. Calibration only.")
out = base / "model/decoder15m/leek-review.bin"
# Fold the projection of each possible continuation embedding into a table.
# Swift can now evaluate the head from one normal transformer forward pass.
left_w, token_w, right_w = weights.split(384)
token_scores = model.emb.weight.detach() @ token_w
with out.open("wb") as f:
    f.write(b"MBH1")
    f.write(torch.cat([bias, left_w, right_w, token_scores]).numpy().astype("<f4").tobytes())
