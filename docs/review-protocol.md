# Review protocol

Every Anvil piece passes through the same loop before it is considered done:

1. **Build.** A builder agent (or maintainer) implements the piece against the
   spec in `docs/plan.md`, with fresh context and no knowledge of other
   pieces' reviews.
2. **Blind pairing.** `tools/review/anonymize.py` copies the finished artifact
   ("ours") and GrapheneOS's nearest equivalent ("theirs" — always the real
   upstream artifact, cloned or fetched, never a description of it) into two
   anonymous directories, `candidate_A` and `candidate_B`, with a randomized
   assignment.
3. **Critic.** A separate agent with fresh context receives both candidates,
   the piece spec, and nothing else. It judges craft — correctness, rigor,
   honesty, completeness — picks a winner, and names the single biggest gap in
   the loser. It is told the artifacts are one Anvil piece and one GrapheneOS
   artifact but not which is which.
4. **Loop.** If the critic picks GrapheneOS's artifact, the named gap goes back
   to the builder and the piece iterates (new builder round, fresh critic).
   The loop repeats until the critic picks Anvil's artifact blind.
5. **Ledger.** Every round's verdict and the named gap are recorded in
   `progress/progress.json` and rendered on the live progress page. A piece
   that cannot win within three rounds is marked `failed` and the gap is
   documented — we do not silently re-roll.

The point is not to "beat" GrapheneOS at their own game — upstream wins any
comparison of mature, production-proven code, and we integrate rather than
fork. The point is that every Anvil artifact must be able to *win its own
comparison honestly*: our portability layer against the absence of one, our
matrix breadth against a Pixel-only list, our verification tooling against
manual process. Where upstream's artifact is genuinely better for a use case,
the protocol forces that into the open and it goes in our docs.
