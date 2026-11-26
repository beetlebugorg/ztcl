# Writing

These rules apply to commit messages, PR bodies, code comments, and docs.

Say what changed and why. Leave out summaries of the work, reflection on it, and statements of its significance.

## Avoid these constructions

- Reversals: "Pinned, not changed." State the thing and drop the contrast.
- Dramatic negatives: "And ran nothing."
- Aphorisms and figures of speech.
- Fragments for emphasis. Write the full sentence.
- Personified subjects: "The fix buys us."
- Filler verbs: carries, takes, brings, lands, sits. Use has, is, or goes in.
- Editorial asides: "Worth noting."
- Lists of three built for rhythm.
- Human verbs for code. Code does not know, say, want, decide, or refuse. Name the mechanism.

## Voice

Use US English. Write a number of five or more digits with commas between the groups of three digits: 10,000, 37,413, 1,000,000. Do not separate the groups with spaces. Leave numbers in code, in test data, and in program output as they are. Use present tense for what the code does and past tense for what it did. Keep sentences short and active, with one idea in each. Do not use em dashes. Do not join two clauses with a semicolon for effect.

## Terms

The limit of CPU work is the compute limit, and it counts compute units. Use these two terms in code, docs, and messages. Do not call the limit a step limit or fuel, and do not call a unit a step. [Limits](docs/limits.md#the-compute-limit) defines a compute unit.

## Commit messages

Keep the subject under 72 characters. Wrap the body at 72. Give what changed and the one fact a reviewer needs. Add no attribution trailers or session links, and no references to ignored paths.

## PR bodies

Do not hard wrap. Put one paragraph on each line.

## Before you publish

Search for these strings. Justify or remove each hit: `—`, `, not `, `nothing`, `would`, `carries`, `takes`, `worth`, `which is`.

## Scope

Do what the task asks. Ask before you fix an adjacent problem.

## Claims

Write only facts that you checked. If you cannot check a fact, say so in the sentence.
