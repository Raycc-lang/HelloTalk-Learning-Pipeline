# Transcript Regenerator

The original ASR transcript (merged.txt) is unstructured, messy data — no punctuation, no capitalization, no speaker labels, garbled words, repeated segments, and counting recitation mixed in. It cannot be fed directly into a 4/3/2 drill generator as context.

This prompt regenerates a clean, structured transcript using the grammar.md and semantic.md analysis files as **anchor points**. The analysis entries contain exact quotes from what the learner said (ERROR FORM, ORIGINAL PHRASE) — these are the reliable reference points to locate corresponding segments in the raw transcript and clean them.

---

## INPUT

**1. Raw transcript (merged.txt)** — the messy ASR output. May contain:
- No punctuation or capitalization
- No speaker labels
- Garbled or hallucinated words
- Repeated segments
- Counting recitation mixed with conversation
- Fragments from multiple speech turns run together

**2. Grammar analysis (grammar.md)** — structured analysis of grammatical errors:
```
PATTERN NAME: [rule-referenced name]
CARD TYPE: [FILL_IN_BLANK / CORRECT_THE_ERROR]
FREQUENCY: [count or SINGLE INSTANCE]
ERROR FORM:
  — [the learner's actual erroneous utterance, verbatim or normalized]
CORRECT ANCHORS:
  — [natural corrected version]
WHY IT MATTERS: [comprehension impact]
INTERFERENCE NOTE: [L1 explanation]
```

**3. Semantic analysis (semantic.md)** — structured analysis of lexical/chunk errors:
```
SUB-TYPE: [SEMANTIC BOUNDARY ERROR / MISSED IDIOMATIC PHRASING / NEAR-MISS COLLOCATION]
ORIGINAL PHRASE: [the learner's actual attempted phrase]
INTENT: [what the learner meant to say]
NATIVE CHUNKS: [target expressions]
...
```

---

## Method

1. **Extract anchor phrases** from grammar.md (ERROR FORM lines) and semantic.md (ORIGINAL PHRASE lines). These are verbatim or near-verbatim utterances the learner actually produced.

2. **Locate each anchor phrase** in the raw merged.txt. The raw transcript will contain the same utterance, possibly with:
   - Minor ASR differences (word substitutions by the speech model)
   - Extra context before and after (filler, repetition, other speakers' turns)
   - Broken across lines or interleaved with other speech

3. **For each located segment**, reconstruct:
   - What the learner was trying to say (from analysis entries: INTENT, CORRECT ANCHORS)
   - The conversational context (what triggered the utterance, what followed)
   - Topic grouping (which utterances belong to the same conversational thread)

4. **Assemble into a clean transcript.**

---

## OUTPUT FORMAT

A clean, speaker-labeled transcript with topics grouped.

```
## Topic: [topic label]

**Context:** [1-2 sentences describing the situation]

Learner: [clean utterance — the learner's speech, with punctuation and capitalization, preserving the actual errors but in a readable form]

[Other speaker's turn, if reconstructable — mark as "Other:" or skip if unclear]

Learner: [next learner utterance]
...

---

## Topic: [next topic]
...
```

**Rules:**
- Preserve the learner's actual errors exactly — this transcript feeds the 4/3/2 drill generator, which needs to see the raw production
- Add punctuation and capitalization for readability
- Remove garbled non-word segments unless context makes them recoverable with high confidence
- Remove counting recitation (1-2-3-4 sequences), repeated filler sequences
- Group by topic conversation turns (topic shifts = new section)
- Label the learner as "Learner:" and other speakers as "Other:" when reconstructable
- If speech is clearly from another person and the learner's side is absent, include as context for the conversation (mark "Other:")
- Each topic section should include all the learner's utterances in that conversation thread

Now process the following inputs:
