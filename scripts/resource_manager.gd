class_name ResourceManager
extends RefCounted

## Identified integration point for the resource-generation system
## (see docs/resource-generation-plan.md, docs/architecture.md §8).
## Empty stub only - no logic yet. Will follow the same shape as
## BiomeClassifier: stateless static functions that consume an
## already-computed WorldGen.sample() Dictionary (and, later, a
## BiomeClassifier.classify_full() result) rather than recomputing any
## environmental field themselves.
