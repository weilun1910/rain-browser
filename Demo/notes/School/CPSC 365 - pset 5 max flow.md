---
id: note-cpsc365-pset5
title: CPSC 365 - pset 5 max flow
space: school
created: 2026-10-06T19:20:00-04:00
updated: 2026-10-07T23:55:00-04:00
tags: [cpsc365, algorithms, pset]
---

# CPSC 365 - pset 5 max flow

Due Thursday 11:59pm. Office hours Wed 4-6 in AKW.

## Problem 1: max-flow min-cut
- Run Ford-Fulkerson until there's no augmenting path left in the residual network
- Take S = every vertex reachable from the source in the final residual network
- Every edge out of S is saturated and every edge into S carries zero flow, so the flow value equals the capacity of the cut (S, V - S)
- Any flow is at most any cut, so this flow is maximum and this cut is minimum

## Problem 2: assigning TAs to sections
- Bipartite matching as a flow network: source to each TA with capacity 2 (max sections), TA to section if available with capacity 1, section to sink with capacity 1
- A max flow of value equal to the number of sections means every section is covered
- Integrality theorem gives an integer flow, so it's a real assignment

## Problem 3: circulation with demands
- Each node has a supply or a demand, d(v). Add a super source to the supply nodes and a super sink from the demand nodes
- Feasible if and only if the max flow saturates every edge out of the super source
- Careful with lower bounds on edges: subtract them first, then adjust the demands

## Stuck on
- 3(b), the proof that the reduction preserves feasibility in both directions. Ask at office hours.
- Running time for Edmonds-Karp is O(VE^2). Don't confuse it with plain Ford-Fulkerson, which depends on the max flow value.
