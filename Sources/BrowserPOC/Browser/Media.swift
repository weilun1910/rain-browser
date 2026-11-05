import Foundation
import WebKit

/// Watches audio and video in pages from an isolated script world. Pages report when something
/// plays or stops. The app can mute, pause, play and ask for picture in picture through the same world.
@MainActor
final class MediaWatch: NSObject, WKScriptMessageHandler {
    static let shared = MediaWatch()
    static let name = "bpocMedia"
    static let world = WKContentWorld.world(name: "bpocMedia")
    weak var model: BrowserModel?

    static let script = """
    (() => {
      if (window.__bpocMedia) return; window.__bpocMedia = true;
      let muted = false;
      const all = () => Array.from(document.querySelectorAll('video, audio'));
      const state = () => {
        const playing = all().filter(e => !e.paused && !e.ended && e.readyState > 1);
        return { playing: playing.length > 0, video: playing.some(e => e.tagName === 'VIDEO'),
                 audible: playing.some(e => !e.muted && e.volume > 0) };
      };
      let last = '';
      const post = () => {
        const s = state(); const k = JSON.stringify(s);
        if (k === last) return; last = k;
        try { window.webkit.messageHandlers.bpocMedia.postMessage(s); } catch (_) {}
      };
      ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'].forEach(ev => document.addEventListener(ev, (e) => {
        const t = e.target;
        if (muted && t && (t.tagName === 'VIDEO' || t.tagName === 'AUDIO') && !t.muted) t.muted = true;
        setTimeout(post, 0);
      }, true));
      window.__bpocMediaCmd = (cmd) => {
        const els = all();
        if (cmd === 'mute') { muted = true; els.forEach(e => { e.muted = true; }); }
        else if (cmd === 'unmute') { muted = false; els.forEach(e => { e.muted = false; }); }
        else if (cmd === 'pause') { els.forEach(e => e.pause()); }
        else if (cmd === 'play') { const e = els.find(x => x.paused && x.currentTime > 0) || els[0]; if (e) e.play(); }
        else if (cmd === 'pip') {
          const v = els.find(x => x.tagName === 'VIDEO' && !x.paused && !x.muted);
          if (v && v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) v.webkitSetPresentationMode('picture-in-picture');
        }
        setTimeout(post, 50);
        return true;
      };
    })();
    """

    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        controller.add(shared, contentWorld: world, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        let playing = (body?["playing"] as? Bool) ?? false
        let video = (body?["video"] as? Bool) ?? false
        guard let wv = message.webView, let t = tab(for: wv) else { return }
        if t.mediaPlaying != playing { t.mediaPlaying = playing }
        if t.hasVideo != video { t.hasVideo = video }
        model?.objectWillChange.send()
    }

    func tab(for wv: WKWebView) -> Tab? {
        if let m = model {
            if let t = m.tabs.first(where: { $0.webView === wv }) { return t }
            if let p = m.peek, p.tab.webView === wv { return p.tab }
        }
        return LittleArc.shared.tabs.first { $0.webView === wv }
    }

    static func command(_ cmd: String, in tab: Tab) {
        tab.webView?.evaluateJavaScript("window.__bpocMediaCmd && window.__bpocMediaCmd('\(cmd)')", in: nil, in: world) { _ in }
    }

    static func setMuted(_ muted: Bool, in tab: Tab) { command(muted ? "mute" : "unmute", in: tab) }
}

extension BrowserModel {
    /// Tabs off screen that are playing something, for the sidebar's media controls.
    var playingElsewhere: [Tab] {
        let shown = Set(visibleTabs.map { $0.id })
        return tabs.filter { $0.mediaPlaying && !shown.contains($0.id) }
    }

    func toggleMute(_ tab: Tab) {
        tab.isMuted.toggle()
        MediaWatch.setMuted(tab.isMuted, in: tab)
        scheduleSave()
    }

    func togglePlayback(_ tab: Tab) {
        MediaWatch.command(tab.mediaPlaying ? "pause" : "play", in: tab)
    }

    /// Picture in picture when you leave a tab with a playing video, unless it's muted.
    func mediaSelectionChanged(leaving: [Tab]) {
        guard BrowserPrefs.shared.value.autoPictureInPicture else { return }
        let shown = Set(visibleTabs.map { $0.id })
        for t in leaving where t.mediaPlaying && t.hasVideo && !t.isMuted && !shown.contains(t.id) {
            MediaWatch.command("pip", in: t)
        }
    }
}
