# Things to try in the demo

The demo profile belongs to Theo Park, a made-up Yale '28 student. He's writing a seminar paper on why campus marketplaces stall, building a textbook swap app called Swapshelf with his friend Sam, applying for PM internships, and planning a trip to Japan in January. Everyone he talks to and every company he applies to is made up. The web pages are real, so tabs open the actual page.

Run `scripts/demo.sh` from the app folder. It makes the profile the first time and opens a separate copy of the app on it, so your own profile isn't touched. `scripts/demo.sh --reset` starts it over.

It's set on Wednesday 4 November in the afternoon. Times shift when the profile is seeded, so "three weeks ago" stays true whenever you run it.

Spaces are on Ctrl-1 to Ctrl-4: School, Swapshelf, Job hunt, Personal. The Google Docs, Notion pages and Granola meetings open as read-only copies inside the browser. The notes are real files in the demo profile, so you can type in them.

## Writing the paper

The demo opens here. School space, with an article on the chicken-or-egg problem on the left and Theo's half-written section 2 on the right.

- Notes / Docs should show the Oct 16 check-in with Prof. Hartley. Its action items are the checklist at the top of the draft.
- The coffee chat with Nadia Brooks should show up too. It lives in Job hunt and nothing links it to the paper. It matches because Errandly launched one neighbourhood at a time and paid runners a guarantee until demand caught up, which is the paper's argument at city scale.
- Sites should have the Wikipedia history of Facebook, since the draft talks about Facebook going college by college in 2004.
- Click the article pane. The Nadia note should stay. Andrew Chen's cold start essay should come in.
- Only "Paper outline v2" should ever show up. The older "Paper outline" is nearly the same file and shouldn't appear next to it.

## A plan that matches something from six weeks ago

Ctrl-2 for Swapshelf. It opens on the pilot launch plan Theo wrote in Google Docs on Nov 2.

- Sites should bring back Paul Graham's "Do Things that Don't Scale". Theo read it on Sep 25 for the paper, in the School space, and never pinned or filed it. The plan is basically that essay put into practice: recruit by hand, go door to door, install the app on the spot, no big launch.
- Notes / Docs should have the Oct 29 sync where Sam and Theo assigned the plan, and the pilot metrics note.
- There's a Notion roadmap and a stale Markdown copy of it. At most one of them should show.

## Meeting notes while you write

Ctrl-3 for Job hunt. Theo is drafting behavioral stories next to the Wikipedia page on STAR.

- The mock interview with Priya Raman should show up. Its action items asked for exactly these stories.
- The pickup points decision from Swapshelf should show up as well, because the conflict story is that decision.
- The Japan planning call says "Priya" all the way through, but that's Priya Kapoor, a friend coming on the trip. It shouldn't show up here.

## The traps

Things that share words without sharing meaning. None of these should turn into cards.

- In Swapshelf, open "SwiftUI - launch time and list performance" from the Build folder. It's about an app's cold start. Apple's launch time doc should show up. Nothing from the paper's cold start reading should.
- In Personal, the flights note should pull in Haneda, the trip call and the budget sheet. Apple's TestFlight page shouldn't come anywhere near it.
- Press Cmd-T and type "multihoming". There are two Wikipedia pages in the history. One is the economics idea. The other is about connecting a computer to two networks, and Theo left it after 20 seconds. Only the first belongs with the paper.
- The CPSC 365 notes on max flow are full of words like network, supply and demand. They should stay out of the paper's cards.

## The graph

Open the graph from anywhere.

- Four clusters, one per space, in the space colours.
- The Nadia coffee chat is the best bridge to look at. It sits between Job hunt and School because of what it says, and it has a real link to "Tokyo food list" in Personal, since she recommended a ramen place in Shinjuku.
- Paul Graham's essay should connect School to Swapshelf.
- The Hartley check-in should connect to the Swapshelf pilot metrics, because she asked for the pilot numbers.
- The estimation practice note in Job hunt (how many textbooks change hands at Yale) should sit close to Swapshelf.
- "Weekly plan - Nov 2" is an Essential and links into every space, so it should look like a hub.
- The near-duplicates should sit right on top of each other: the two outlines, the roadmap and its export, and the two Wikipedia "Network effect" pages.
- The CPSC 365 notes should float off on their own even though they say "network" a lot.

## Make your own connection

- Open "Tokyo food list" in Personal. The Wikipedia page on tsukemen should come up, and probably the Nadia coffee chat, since rare words like Fuunji carry a lot of weight.
- Or start a new note in School and write a few lines about fill rate, and whether a city marketplace can keep runners once the earnings guarantee ends. Pause typing. The Nadia note and the Errandly research page in Notion should appear.

`expected.json` has the full list of what should and shouldn't show for each of these, and the engine eval uses the same cases. If a card is missing, that's where to check whether it's the engine or the data.
