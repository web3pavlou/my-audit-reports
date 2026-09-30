# Firelight Audit Competition

This directory contains my submissions and supporting material from the **Firelight Audit Competition**, run through Immunefi.

For me, this competition was a particularly disheartening introduction to competitive security research.

## My Experience

My experience of the competition included:

* findings being downgraded, assessed against assumptions about off-chain components that researchers could not actually audit;
* findings with reproducible PoCs being rejected by the project with explanations I consider technically unconvincing, not saying utterly wrong;

I approached this competition as a serious attempt to build a career in security research, and I believe I performed well. I finished in the top 10 among 132 security researchers, so this is not intended as a "cry me a river" reference, but rather as a factual record of how the competition unfolded from my perspective.


The result was:

```text
$160 spent on submissions and fees

3 valid findings
5 invalid findings

Damage: $66 
```

## The Part That Stuck With Me

What troubles me most is not simply losing a submission.

It is seeing a finding survive detailed technical scrutiny, have its core claims recognized during triage, and then still be closed by the project on reasoning that I believe does not address the actual mechanism demonstrated by the PoC.

That is the purpose of keeping the disputed material here.

I want the original technical argument, the PoC results, the project's response, and my replies to remain available together rather than reducing the episode to a simple "invalid" label.

## The Disputed L-1 Finding

The main example preserved in this directory is:

**L-1 — `VaultRewardDistributor` credits emissions only to live shares while `FirelightVault::payout` slashes pending-withdrawal buckets**

The finding demonstrates, through a Foundry PoC, an accounting asymmetry between:

```text
loss allocation → active assets + pending withdrawal buckets

reward allocation → live shares only
```

The PoC contains four tests:

1. The main finding.
2. A control showing that rewards split proportionally when no withdrawal is pending.
3. A control showing that the slash itself is proportional when no distribution occurs.
4. A test showing that repeated distributions rebuild the live-share cohort while the slashed withdrawal bucket remains unchanged.

The project ultimately rejected the finding as **by design**, citing an existing accepted risk concerning new deposits capturing pending reward distributions.

My position is that this does not address the reported mechanism: that accepted risk concerns the **entry side**, while L-1 concerns the **exit side**. An exiting staker remains exposed to loss through the withdrawal buckets while being excluded from the corresponding emissions.

The technical details, PoC output, and the full exchange are preserved in the files below.

## Files

### `validFindings.pdf`

A PDF containing the findings from the competition that were considered valid.

### `L1-invalidated.pdf`

A PDF containing the complete L-1 finding, including its technical analysis and PoC.

The file also contains a **chronology of the dispute**: the original submission, Immunefi's escalation analysis, the project's closure response, my rebuttal, subsequent Immunefi interaction, and my follow-up asking for the finding to be re-examined.

## Why I Am Publishing This

This is not intended as a substitute for the original competition record.

It is a permanent record of what I submitted, what was technically demonstrated, what the triage process acknowledged, what the project decided, and how I responded.

Competitive security research is changing rapidly. Bugs increasingly emerge from automated analysis, AI-assisted workflows, and increasingly sophisticated research pipelines. That does not make deep manual understanding irrelevant, but it does change the competitive environment for novice researchers entering the space. This is at least my point of view.

This competition made that reality very clear to me.

I was taught that becoming a strong security researcher meant deeply understanding a protocol, tracing its invariants, understanding its architecture, and manually hunting for places where those assumptions break, but those seem rather distant in the wild.

I still believe those skills matter.

What I am less certain about is whether they are enough, on their own, in the current competitive environment.

This folder is part of my attempt to document that experience rather than quietly move on from it.

Thank you to everyone who took the time to read this.
