#!/usr/bin/env python3
"""Builds Demo/history.json from the curated page list below.

Every page is fetched once with a plain, cookie-free GET to confirm it loads and to take
its real title and a short excerpt. Wikipedia excerpts come from its public summary API.
Visit times are laid out deterministically from the dates listed for each page, in New
York time, so a rebuild gives the same history.

    python3 -I Demo/tools/build_history.py            # fetch, check, write history.json
    python3 -I Demo/tools/build_history.py --offline  # reuse the cache, fetch nothing

The cache lives in the worktree's tmp/ folder and is never committed.
"""
import concurrent.futures
import datetime as dt
import hashlib
import html
import json
import random
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
DEMO = HERE.parent
CACHE = DEMO.parent / "tmp" / "demo-history-cache.json"
OUT = DEMO / "history.json"
TZ = ZoneInfo("America/New_York")
ANCHOR = dt.datetime(2026, 11, 4, 16, 40, tzinfo=TZ)
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

W = "https://en.wikipedia.org/wiki/"

# id, url, space, query that led there (or None), visit dates (MM-DD, one visit each), dwell minutes
PAGES = [
    # School: the platforms paper
    ("web-wiki-network-effect", W + "Network_effect", "school", "network effects definition", "09-24 10-02 10-16 11-03", 11),
    ("web-wiki-network-effects-redirect", W + "Network_effects", "school", "network effects economics", "09-23", 3),
    ("web-wiki-two-sided-market", W + "Two-sided_market", "school", "two sided market rochet tirole", "09-24 10-09 10-18 11-02", 14),
    ("web-wiki-metcalfes-law", W + "Metcalfe%27s_law", "school", None, "09-24", 3),
    ("web-wiki-critical-mass", W + "Critical_mass_(sociodynamics)", "school", "critical mass network adoption", "10-03 11-02", 6),
    ("web-wiki-multihoming-ip", W + "Multihoming", "school", "multihoming", "10-18", 0.3),
    ("web-wiki-jean-tirole", W + "Jean_Tirole", "school", None, "10-09", 4),
    ("web-wiki-platform-economy", W + "Platform_economy", "school", "platform economy", "09-23", 5),
    ("web-wiki-sharing-economy", W + "Sharing_economy", "school", None, "09-23", 2),
    ("web-wiki-craigslist", W + "Craigslist", "school", "craigslist unbundling", "10-10", 4),
    ("web-wiki-uber", W + "Uber", "school", None, "10-18", 3),
    ("web-wiki-lyft", W + "Lyft", "school", None, "10-18", 2),
    ("web-wiki-airbnb", W + "Airbnb", "school", None, "09-25", 4),
    ("web-wiki-bandwagon-effect", W + "Bandwagon_effect", "school", None, "10-03", 2),
    ("web-wiki-switching-cost", W + "Switching_cost", "school", "switching costs multi-homing", "10-19", 5),
    ("web-wiki-history-of-facebook", W + "History_of_Facebook", "school", "facebook 2004 launch harvard then other colleges", "10-20 11-03", 9),
    ("web-wiki-tinder", W + "Tinder_(app)", "school", "tinder usc launch campus", "10-20", 4),
    ("web-wiki-chicken-or-egg", W + "Chicken_or_the_egg", "school", None, "09-24", 1),
    ("web-pg-do-things-that-dont-scale", "https://paulgraham.com/ds.html", "school", "paul graham do things that don't scale", "09-25", 14),
    ("web-gurley-all-markets", "https://abovethecrowd.com/2012/11/13/all-markets-are-not-created-equal-10-factors-to-consider-when-evaluating-digital-marketplaces/", "school", "bill gurley all markets are not created equal", "09-26 10-10", 18),
    ("web-stratechery-aggregation-theory", "https://stratechery.com/2015/aggregation-theory/", "school", "aggregation theory ben thompson", "09-29", 12),
    ("web-nfx-network-effects-manual", "https://www.nfx.com/post/network-effects-manual", "school", "nfx network effects manual", "09-30 10-16", 15),
    ("web-nfx-chicken-or-egg-tactics", "https://www.nfx.com/post/19-marketplace-tactics-for-overcoming-the-chicken-or-egg-problem", "school", "marketplace chicken or egg problem tactics", "11-03 11-04", 16),
    ("web-andrewchen-cold-start-social", "https://andrewchen.com/how-to-solve-the-cold-start-problem-for-social-products/", "school", "andrew chen cold start problem", "10-02", 7),
    ("web-a16z-cold-start-book", "https://a16z.com/books/the-cold-start-problem/", "school", None, "10-02", 3),
    ("web-lenny-kickstart-marketplace", "https://www.lennysnewsletter.com/p/how-to-kickstart-and-scale-a-marketplace", "school", "how to kickstart a marketplace lenny", "10-21 11-02", 10),
    ("web-nobel-tirole-facts", "https://www.nobelprize.org/prizes/economic-sciences/2014/tirole/facts/", "school", None, "10-09", 2),
    ("web-nobel-2014-popular", "https://www.nobelprize.org/prizes/economic-sciences/2014/popular-information/", "school", None, "10-09", 6),
    ("web-hbr-two-sided-strategies", "https://hbr.org/2006/10/strategies-for-two-sided-markets", "school", "strategies for two-sided markets hbr eisenmann", "10-09", 5),
    ("web-nber-uber-flexible-work", "https://www.nber.org/papers/w23296", "school", "uber drivers also drive for lyft evidence", "10-19 11-03", 8),
    ("web-nber-uber-consumer-surplus", "https://www.nber.org/papers/w22627", "school", None, "10-19", 3),
    ("web-wiki-dynamic-pricing", W + "Dynamic_pricing", "school", None, "10-19", 3),
    ("web-wiki-winner-take-all", W + "Winner-take-all_market", "school", None, "10-10", 3),
    ("web-wiki-economies-of-scale", W + "Economies_of_scale", "school", None, "10-03", 2),
    ("web-wiki-monopolistic-competition", W + "Monopolistic_competition", "school", None, "10-03", 2),
    ("web-wiki-market-liquidity", W + "Market_liquidity", "school", "marketplace liquidity definition", "10-17", 0.5),
    ("web-wiki-etsy", W + "Etsy", "school", None, "10-10", 2),
    ("web-wiki-ebay", W + "EBay", "school", None, "10-10", 3),
    ("web-wiki-amazon-marketplace", W + "Amazon_Marketplace", "school", None, "10-10", 2),
    ("web-wiki-opentable", W + "OpenTable", "school", "opentable restaurant software before diners", "10-21", 4),
    ("web-chicago-author-date", "https://www.chicagomanualofstyle.org/tools_citationguide/citation-guide-2.html", "school", "chicago author date citation", "11-02", 4),
    # School: CPSC 365
    ("web-wiki-max-flow-min-cut", W + "Max-flow_min-cut_theorem", "school", "max flow min cut proof", "10-06 10-07 10-27", 12),
    ("web-wiki-ford-fulkerson", W + "Ford%E2%80%93Fulkerson_algorithm", "school", None, "10-06 10-27", 9),
    ("web-wiki-flow-network", W + "Flow_network", "school", None, "10-06", 4),
    ("web-wiki-dijkstra", W + "Dijkstra%27s_algorithm", "school", None, "10-05", 5),
    ("web-wiki-stable-marriage", W + "Stable_marriage_problem", "school", "gale shapley proof", "10-28", 8),
    # Swapshelf
    ("web-apple-swiftui", "https://developer.apple.com/documentation/swiftui", "swapshelf", None, "09-27 10-04 10-11", 6),
    ("web-apple-swiftui-list", "https://developer.apple.com/documentation/swiftui/list", "swapshelf", "swiftui list performance large data", "10-11 10-12", 7),
    ("web-apple-launch-time", "https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time", "swapshelf", "ios cold launch time swiftui", "10-23", 9),
    ("web-apple-testflight", "https://developer.apple.com/testflight/", "swapshelf", "testflight external testers limit", "10-29 11-02", 5),
    ("web-apple-review-guidelines", "https://developer.apple.com/app-store/review/guidelines/", "swapshelf", None, "10-30", 6),
    ("web-apple-user-notifications", "https://developer.apple.com/documentation/usernotifications", "swapshelf", "ios push notification swiftui", "10-15", 5),
    ("web-apple-hig-onboarding", "https://developer.apple.com/design/human-interface-guidelines/onboarding", "swapshelf", None, "10-14", 4),
    ("web-apple-sf-symbols", "https://developer.apple.com/sf-symbols/", "swapshelf", None, "10-04", 2),
    ("web-apple-mapkit", "https://developer.apple.com/documentation/mapkit", "swapshelf", "mapkit swiftui pin annotation", "10-21", 6),
    ("web-apple-swiftdata", "https://developer.apple.com/documentation/swiftdata", "swapshelf", "swiftdata offline cache", "10-13", 4),
    ("web-supabase-auth", "https://supabase.com/docs/guides/auth", "swapshelf", None, "10-01 10-02", 8),
    ("web-supabase-rls", "https://supabase.com/docs/guides/database/postgres/row-level-security", "swapshelf", "supabase row level security", "10-02 10-16", 9),
    ("web-supabase-ios-quickstart", "https://supabase.com/docs/guides/getting-started/quickstarts/ios-swiftui", "swapshelf", None, "09-30", 5),
    ("web-supabase-realtime", "https://supabase.com/docs/guides/realtime", "swapshelf", "supabase realtime chat", "10-22", 5),
    ("web-github-supabase-swift", "https://github.com/supabase/supabase-swift", "swapshelf", None, "10-01", 3),
    ("web-postgres-constraints", "https://www.postgresql.org/docs/current/ddl-constraints.html", "swapshelf", "postgres unique constraint two columns", "10-16", 4),
    ("web-swift-api-guidelines", "https://www.swift.org/documentation/api-design-guidelines/", "swapshelf", None, "09-28", 2),
    ("web-hws-async-await", "https://www.hackingwithswift.com/swift/5.5/async-await", "swapshelf", "swift async await mainactor", "10-12", 8),
    ("web-pg-startup-ideas", "https://paulgraham.com/startupideas.html", "swapshelf", "how to get startup ideas paul graham", "09-23", 13),
    ("web-pg-growth", "https://paulgraham.com/growth.html", "swapshelf", None, "10-25", 9),
    ("web-pg-schlep", "https://www.paulgraham.com/schlep.html", "swapshelf", None, "09-23", 4),
    ("web-pg-13-sentences", "https://www.paulgraham.com/13sentences.html", "swapshelf", None, "10-26", 3),
    ("web-wiki-mvp", W + "Minimum_viable_product", "swapshelf", None, "09-24", 3),
    ("web-mom-test", "https://www.momtestbook.com/", "swapshelf", "the mom test customer interviews", "10-04", 5),
    ("web-wiki-nps", W + "Net_promoter_score", "swapshelf", None, "10-30", 2),
    ("web-wiki-cohort-analysis", W + "Cohort_analysis", "swapshelf", "cohort retention analysis", "10-30", 4),
    ("web-lenny-good-retention", "https://www.lennysnewsletter.com/p/what-is-good-retention-issue-29", "swapshelf", "what is good retention consumer app", "10-30 11-03", 9),
    ("web-wiki-yale-residential-colleges", W + "Residential_colleges_of_Yale_University", "swapshelf", None, "10-20", 5),
    ("web-wiki-branford-college", W + "Branford_College", "swapshelf", None, "10-20", 3),
    ("web-wiki-saybrook-college", W + "Saybrook_College", "swapshelf", None, "10-20", 2),
    ("web-wiki-textbook", W + "Textbook", "swapshelf", "textbook prices college students", "09-24", 6),
    ("web-wiki-freecycle", W + "The_Freecycle_Network", "swapshelf", "freecycle how it works", "09-26", 4),
    ("web-wiki-online-marketplace", W + "Online_marketplace", "swapshelf", None, "09-26", 3),
    ("web-wiki-buy-nothing", W + "Buy_Nothing_Project", "swapshelf", None, "09-26", 4),
    # Job hunt
    ("web-wiki-product-manager", W + "Product_manager", "job-hunt", None, "09-23", 3),
    ("web-wiki-product-management", W + "Product_management", "job-hunt", None, "09-23", 4),
    ("web-wiki-star-method", W + "Situation,_task,_action,_result", "job-hunt", "STAR method behavioral interview", "10-23 11-03", 5),
    ("web-wiki-fermi-problem", W + "Fermi_problem", "job-hunt", "fermi estimation interview", "10-24", 6),
    ("web-wiki-odi", W + "Outcome-Driven_Innovation", "job-hunt", "jobs to be done framework", "10-22", 4),
    ("web-norton-how-to-hire-pm", "https://www.bringthedonuts.com/essays/productmanager.html", "job-hunt", "ken norton how to hire a product manager", "09-28", 11),
    ("web-a16z-good-pm-bad-pm", "https://a16z.com/good-product-manager-bad-product-manager/", "job-hunt", None, "09-28", 6),
    ("web-svpg-product-vs-feature-teams", "https://www.svpg.com/product-vs-feature-teams/", "job-hunt", None, "10-26", 9),
    ("web-productplan-rice", "https://www.productplan.com/glossary/rice-scoring-model/", "job-hunt", "RICE prioritization", "10-22", 4),
    ("web-wiki-moscow", W + "MoSCoW_method", "job-hunt", None, "10-22", 2),
    ("web-wiki-kano", W + "Kano_model", "job-hunt", None, "10-22", 3),
    ("web-amplitude-north-star", "https://amplitude.com/blog/product-north-star-metric", "job-hunt", "north star metric examples", "10-22 10-31", 7),
    ("web-yale-ocs", "https://ocs.yale.edu/", "job-hunt", None, "09-23 10-01", 3),
    ("web-wiki-informational-interview", W + "Informational_interview", "job-hunt", "informational interview questions", "10-05", 3),
    ("web-wiki-cover-letter", W + "Cover_letter", "job-hunt", None, "10-02", 2),
    ("web-wiki-resume", W + "R%C3%A9sum%C3%A9", "job-hunt", None, "09-29", 2),
    ("web-inkandswitch-local-first", "https://www.inkandswitch.com/essay/local-first/", "job-hunt", "local-first software ink and switch", "10-25 10-26", 22),
    ("web-matuschak-evergreen-notes", "https://notes.andymatuschak.org/z5E5QawiXCMbtNtupvxeoEX", "job-hunt", None, "10-25", 8),
    ("web-wiki-zettelkasten", W + "Zettelkasten", "job-hunt", None, "10-25", 4),
    ("web-wiki-pkm", W + "Personal_knowledge_management", "job-hunt", None, "10-25", 3),
    ("web-wiki-crdt", W + "Conflict-free_replicated_data_type", "job-hunt", "CRDT explained", "10-26", 7),
    ("web-obsidian", "https://obsidian.md/", "job-hunt", None, "10-26", 3),
    ("web-wiki-gig-economy", W + "Gig_economy", "job-hunt", None, "10-12", 5),
    ("web-wiki-gig-worker", W + "Gig_worker", "job-hunt", None, "10-12", 2),
    ("web-wiki-taskrabbit", W + "TaskRabbit", "job-hunt", "errandly competitors taskrabbit", "10-12", 5),
    ("web-wiki-doordash", W + "DoorDash", "job-hunt", None, "10-13", 3),
    ("web-wiki-instacart", W + "Instacart", "job-hunt", None, "10-13", 2),
    ("web-wiki-design-thinking", W + "Design_thinking", "job-hunt", None, "10-21", 3),
    ("web-wiki-ab-testing", W + "A/B_testing", "job-hunt", None, "10-24", 4),
    # Personal: Japan trip
    ("web-wiki-fushimi-inari", W + "Fushimi_Inari-taisha", "personal", None, "10-25 11-01", 5),
    ("web-wiki-kiyomizu-dera", W + "Kiyomizu-dera", "personal", None, "10-25", 3),
    ("web-wiki-kinkaku-ji", W + "Kinkaku-ji", "personal", None, "10-25", 3),
    ("web-wiki-arashiyama", W + "Arashiyama", "personal", "arashiyama bamboo grove early morning", "10-25", 4),
    ("web-wiki-nara-park", W + "Nara_Park", "personal", "nara day trip from kyoto", "11-03", 4),
    ("web-wiki-todai-ji", W + "T%C5%8Ddai-ji", "personal", None, "11-03", 3),
    ("web-wiki-shinkansen", W + "Shinkansen", "personal", None, "10-24", 4),
    ("web-wiki-japan-rail-pass", W + "Japan_Rail_Pass", "personal", "jr pass worth it 2026", "10-24 10-31", 6),
    ("web-jrpass-official", "https://japanrailpass.net/en/", "personal", None, "10-31", 5),
    ("web-japan-travel", "https://www.japan.travel/en/us/", "personal", None, "10-24", 4),
    ("web-wiki-shinjuku", W + "Shinjuku", "personal", None, "10-27", 3),
    ("web-wiki-shibuya", W + "Shibuya", "personal", None, "10-27", 2),
    ("web-wiki-tsukiji", W + "Tsukiji_fish_market", "personal", "tsukiji outer market breakfast", "10-27", 4),
    ("web-wiki-tsukemen", W + "Tsukemen", "personal", "fuunji tsukemen shinjuku", "10-14", 3),
    ("web-wiki-ramen", W + "Ramen", "personal", None, "10-27", 2),
    ("web-wiki-suica", W + "Suica", "personal", "suica card iphone wallet", "10-31", 3),
    ("web-wiki-narita", W + "Narita_International_Airport", "personal", None, "10-28", 2),
    ("web-wiki-haneda", W + "Haneda_Airport", "personal", "haneda vs narita to shinjuku", "10-28", 3),
    ("web-wiki-gion", W + "Gion", "personal", None, "10-25", 2),
    ("web-wiki-philosophers-walk", W + "Philosopher%27s_Walk", "personal", None, "10-25", 2),
    ("web-wiki-nishiki-market", W + "Nishiki_Market", "personal", None, "10-27", 2),
    ("web-wiki-hakone", W + "Hakone", "personal", "hakone onsen day trip from tokyo", "11-01", 5),
    ("web-wiki-onsen", W + "Onsen", "personal", None, "11-01", 3),
    ("web-wiki-ryokan", W + "Ryokan", "personal", None, "11-01", 3),
    ("web-wiki-kaiseki", W + "Kaiseki", "personal", None, "11-01", 2),
    ("web-wiki-tokyo", W + "Tokyo", "personal", "tokyo weather january", "11-02", 2),
    ("web-wiki-tokyo-metro", W + "Tokyo_Metro", "personal", None, "10-28", 2),
    ("web-tokyo-metro-official", "https://www.tokyometro.jp/en/index.html", "personal", None, "10-28", 3),
    ("web-wiki-meiji-shrine", W + "Meiji_Shrine", "personal", None, "10-27", 2),
    ("web-wiki-shibuya-crossing", W + "Shibuya_Crossing", "personal", None, "10-27", 1),
    ("web-wiki-ana", W + "All_Nippon_Airways", "personal", "jfk to haneda nonstop january", "10-28", 4),
    ("web-wiki-jal", W + "Japan_Airlines", "personal", None, "10-28", 3),
    ("web-wiki-jfk", W + "John_F._Kennedy_International_Airport", "personal", None, "10-28", 2),
    ("web-wiki-hiragana", W + "Hiragana", "personal", None, "10-29 11-02", 6),
    ("web-wiki-spaced-repetition", W + "Spaced_repetition", "personal", "anki japanese beginner deck", "10-29", 4),
    # Personal: running, and the front page Theo checks every few days
    ("web-wiki-half-marathon", W + "Half_marathon", "personal", None, "09-27", 3),
    ("web-wiki-negative-split", W + "Negative_split", "personal", "negative split pacing", "10-04", 2),
    ("web-wiki-fartlek", W + "Fartlek", "personal", None, "10-11", 2),
    ("web-wiki-lsd", W + "Long_slow_distance", "personal", None, "10-18", 2),
    ("web-hacker-news", "https://news.ycombinator.com/", "personal", None, "09-24 09-30 10-07 10-14 10-21 10-28 11-02 11-04", 20),
]

# Searches that didn't end on a page worth keeping, with their times.
EXTRA_SEARCHES = [
    ("yale reading period fall 2026", "2026-10-26T21:05:00-04:00"),
    ("swapshelf app name taken", "2026-09-27T23:40:00-04:00"),
    ("how long does testflight review take", "2026-11-02T22:10:00-05:00"),
    ("errandly series b", "2026-10-12T16:20:00-04:00"),
    ("quillstone notes app review", "2026-10-25T15:02:00-04:00"),
    ("mapleframe apm program", "2026-10-03T11:30:00-04:00"),
    ("kyoto in january crowds", "2026-10-25T20:44:00-04:00"),
    ("rochet tirole 2003 pdf", "2026-10-09T14:12:00-04:00"),
]

HOURS = {"school": (10, 23), "swapshelf": (13, 24), "job-hunt": (9, 18), "personal": (18, 23)}


def fetch(url, accept="text/html,application/xhtml+xml"):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept})
    with urllib.request.urlopen(req, timeout=25) as r:
        ct = r.headers.get("Content-Type", "")
        return r.status, ct, r.geturl(), r.read(3_000_000)


def clean(s):
    s = html.unescape(re.sub(r"<[^>]+>", " ", s))
    s = re.sub(r"\[\d+\]", "", s)
    return re.sub(r"\s+", " ", s).strip()


def polish(s):
    """Undoes the spacing that stripping tags leaves behind, and drops footnote marks,
    pronunciation brackets and unexpanded wiki templates."""
    s = re.sub(r"\{\{.*?\}\}", "", s)
    s = re.sub(r"\[\s*(?:\d+|[a-z]|update|citation needed)\s*\]", "", s)
    s = re.sub(r"\s*\[[^\]]*[^\x00-\x7F][^\]]*\]", "", s)
    s = re.sub(r"\s+([,.;:)\]!?])", r"\1", s)
    s = re.sub(r"([(\[])\s+", r"\1", s)
    s = re.sub(r"\(\s*\)", "", s)
    return re.sub(r"\s+", " ", s).strip()


def trim(s, n=300):
    s = s.strip()
    if len(s) <= n:
        return s
    cut = s[:n]
    end = max(cut.rfind(". "), cut.rfind("? "), cut.rfind("! "))
    if end > n * 0.5:
        return cut[: end + 1]
    return cut.rsplit(" ", 1)[0] + "..."


def meta(page, name):
    for pat in (
        r'<meta[^>]+(?:name|property)=["\']%s["\'][^>]*content=["\']([^"\']*)["\']' % re.escape(name),
        r'<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:name|property)=["\']%s["\']' % re.escape(name),
    ):
        m = re.search(pat, page, re.I)
        if m and m.group(1).strip():
            return clean(m.group(1))
    return ""


def prose(t):
    """True for a run of ordinary sentences, false for menus and tables of contents."""
    words = t.split()
    return len(t) > 90 and len(words) > 14 and sum(1 for c in t if c in ".!?") >= 1 and sum(w[:1].islower() for w in words) > len(words) / 3


# Pages whose text needs JavaScript or changes all day. Their excerpt is written here and flagged.
WRITTEN = {
    "https://news.ycombinator.com/": "The Hacker News front page: links ranked by votes, with discussion threads. It changes all day.",
    "https://www.tokyometro.jp/en/index.html": "Tokyo Metro's official English site, with the route map, fares, ticket types and service updates.",
}


def describe(url):
    """Fetches the page itself (the check) and returns its title and a short excerpt."""
    status, ct, final, body = fetch(url)
    ok = status == 200 and "html" in ct
    page = body.decode("utf-8", "replace")
    m = re.search(r"<title[^>]*>(.*?)</title>", page, re.I | re.S)
    title = clean(m.group(1)) if m else ""
    main = re.sub(r"(?is)<(script|style|nav|header|footer|aside|noscript)[^>]*>.*?</\1>", " ", page)
    excerpt, source = "", "page"
    if url in WRITTEN:
        excerpt, source = WRITTEN[url], "written"
    if not excerpt and "nber.org/papers" in url:
        text = clean(main)
        m = re.search(r"Revision Date [A-Z][a-z]+ \d{4} (.{120,900})", text) or re.search(r"Issue Date [A-Z][a-z]+ \d{4} (.{120,900})", text)
        if m:
            excerpt = m.group(1)
    if not excerpt and "paulgraham.com" in url:
        m = re.search(r"(?:January|February|March|April|May|June|July|August|September|October|November|December) \d{4} (.{120,900})", clean(main))
        if m:
            excerpt = m.group(1)
    if not excerpt:
        d = meta(page, "og:description") or meta(page, "description") or meta(page, "twitter:description")
        if len(d) >= 45:
            excerpt = d
    if not excerpt:
        for p in re.findall(r"<p[^>]*>(.*?)</p>", main, re.I | re.S):
            t = clean(p)
            if prose(t):
                excerpt = t
                break
    if not excerpt:
        excerpt = meta(page, "og:description") or meta(page, "description")
    return {"ok": ok, "status": status, "type": ct, "final": final, "title": title,
            "excerpt": trim(clean(excerpt)), "excerptSource": source}


def wikipedia_summary(url):
    """Wikipedia's own plain-text summary. One request at a time, with a retry, to stay polite."""
    name = urllib.parse.unquote(url[len(W):])
    api = "https://en.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(name, safe="")
    for attempt in range(4):
        try:
            _, _, _, js = fetch(api, accept="application/json")
            data = json.loads(js)
            return data.get("extract", ""), data.get("title", "")
        except Exception:
            time.sleep(1.5 * (attempt + 1))
    return "", ""


def visit_times(pid, space, dates):
    out = []
    lo, hi = HOURS[space]
    for i, d in enumerate(dates.split()):
        month, day = map(int, d.split("-"))
        rng = random.Random(f"{pid}:{d}:{i}")
        day_start = dt.datetime(2026, month, day, tzinfo=TZ)
        if (month, day) == (11, 4):
            lo2, hi2 = 9, 16
        else:
            lo2, hi2 = lo, hi
        minute = rng.randint(lo2 * 60, hi2 * 60 - 1)
        t = day_start + dt.timedelta(minutes=minute)
        if t >= ANCHOR:
            t = ANCHOR - dt.timedelta(minutes=rng.randint(20, 90))
        out.append(t)
    return sorted(out)


def iso(t):
    return t.isoformat(timespec="minutes")


def main():
    offline = "--offline" in sys.argv
    ids = [p[0] for p in PAGES]
    assert len(ids) == len(set(ids)), "duplicate page ids"
    cache = json.loads(CACHE.read_text()) if CACHE.exists() else {}
    todo = [p for p in PAGES if not offline and p[1] not in cache]

    def work(p):
        try:
            return p[1], describe(p[1])
        except Exception as e:
            return p[1], {"ok": False, "status": getattr(e, "code", 0), "error": str(e)[:120]}

    with concurrent.futures.ThreadPoolExecutor(10) as ex:
        for url, info in ex.map(work, todo):
            cache[url] = info
    if not offline:
        for p in PAGES:
            info = cache.get(p[1], {})
            if p[1].startswith(W) and info.get("ok") and not info.get("wiki"):
                extract, _ = wikipedia_summary(p[1])
                if extract:
                    info["excerpt"], info["wiki"] = trim(clean(extract)), True
                time.sleep(1.0)
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(cache, indent=1))

    bad = [p[1] for p in PAGES if not cache.get(p[1], {}).get("ok")]
    for b in bad:
        print("DOES NOT LOAD:", b, cache.get(b))

    pages, searches = [], []
    for pid, url, space, query, dates, dwell in PAGES:
        info = cache.get(url, {})
        times = visit_times(pid, space, dates)
        host = urllib.parse.urlparse(url).netloc
        pages.append({
            "id": pid,
            "url": url,
            "title": info.get("title") or url,
            "site": host[4:] if host.startswith("www.") else host,
            "space": space,
            "query": query,
            "visitCount": len(times),
            "firstVisit": iso(times[0]),
            "lastVisit": iso(times[-1]),
            "visits": [iso(t) for t in times],
            "dwellSeconds": int(round(dwell * 60)),
            "excerpt": trim(polish(info.get("excerpt", ""))),
            "excerptSource": info.get("excerptSource", "page"),
        })
        if query:
            lead = random.Random(pid).randint(15, 75)
            searches.append({"query": query, "at": iso(times[0] - dt.timedelta(seconds=lead)), "led_to": pid})
    for q, at in EXTRA_SEARCHES:
        searches.append({"query": q, "at": at, "led_to": None})
    searches.sort(key=lambda s: s["at"])

    doc = {
        "version": 1,
        "anchor": iso(ANCHOR),
        "timezone": "America/New_York",
        "about": "Real public pages Theo visited in the six weeks before the demo moment. Titles and excerpts were taken from the live pages with a cookie-free request when this file was built. The seeder can fetch full text the same way.",
        "pages": pages,
        "searches": searches,
    }
    OUT.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    visits = sum(p["visitCount"] for p in pages)
    print(f"wrote {OUT.relative_to(DEMO.parent)}: {len(pages)} pages, {visits} visits, {len(searches)} searches, {len(bad)} not loading")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
