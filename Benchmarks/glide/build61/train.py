"""Refit build 61 from shipping feature vectors; fresh replay outcomes are never inputs."""
import argparse
import sys
from pathlib import Path

# The only change to the fitting procedure since 60 is the evidence set and data.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'build60'))
from train import fit, load

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('regression', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('training', type=Path, nargs='+')
    args = parser.parse_args()
    x, y = load(args.training)
    rx, ry = load([args.regression])
    if x.shape[1] != 18 or rx.shape != (68, 18):
        raise ValueError('Expected 18 shipping measurements and 68 decisive regression cases')
    weights = fit((x, y), (rx, ry))
    args.output.write_text('[' + ', '.join(f'{w:.9f}' for w in weights) + ']\n')
    print(f'Fitted {len(y)} training disagreements; protected {len(ry)} regression cases.')

if __name__ == '__main__':
    main()
