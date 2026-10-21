import Foundation

// Local ZEUS Smart AdBlock v3 engine restored from the original app.
struct OriginalShield {
    static let domains: Set<String> = [
        "doubleclick.net", "googleadservices.com", "googlesyndication.com",
        "google-analytics.com", "googletagmanager.com", "facebook.net",
        "scorecardresearch.com", "adnxs.com", "advertising.com",
        "adsystem.com", "admob.com", "inmobi.com", "mopub.com",
        "applovin.com", "unity3d.com", "chartbeat.com", "taboola.com",
        "outbrain.com", "popads.net", "popcash.net", "propellerads.com",
        "adcash.com", "exoclick.com", "clickadu.com", "hilltopads.net",
        "juicyads.com", "trafficjunky.com", "mgid.com", "revcontent.com",
        "criteo.com", "serving-sys.com", "spotxchange.com", "adsrvr.org",
        "pubmatic.com", "rubiconproject.com", "openx.net", "bidswitch.net",
        "casalemedia.com", "lijit.com", "sovrn.com", "ads.twitter.com",
        "amazon-adsystem.com", "smartadserver.com", "truste.com"
    ]
    
    static let allowedDomains: Set<String> = [
        "google.com", "accounts.google.com", "googleapis.com",
        "gstatic.com", "googleusercontent.com", "youtube.com",
        "cloudflare.com", "challenges.cloudflare.com", "turnstile.cloudflare.com",
        "recaptcha.net"
    ]
    
    static let cssSelectors: [String] = [
        ".ad", ".ads", ".advertisement", ".banner", "#ad", "#ads",
        "[id^='google_ads']", "[class*='adsbygoogle']",
        "[class*='popup']", "[id*='popup']", ".modal-overlay",
        "#onetrust-banner-sdk", ".cookie-banner", "#cookie-notice",
        ".fc-ab-root", "iframe[src*='doubleclick']", "iframe[src*='ads']"
    ]
    static func injection(exceptions: [String]) -> String {
        let hosts = String(data: try! JSONEncoder().encode(Array(allowedDomains) + exceptions), encoding: .utf8)!
        return """
        (function() {
            console.log('🛡️ Smart AdBlock Engine v3.0');
            
            var whitelist = \(hosts);
            if (whitelist.some(domain => window.location.hostname === domain || window.location.hostname.endsWith('.' + domain))) {
                return;
            }
        
            window.open = function() { console.log('🚫 Pop-up Killed'); return null; };
            Object.defineProperty(window, 'google_ad_status', { get: function() { return 1; } });
            window.canRunAds = true;
            window.isAdBlockActive = false;
            
            function cleanPage() {
                document.querySelectorAll('iframe').forEach(el => {
                    if (el.src.includes('ads') || el.src.includes('google') || el.offsetWidth < 10) {
                        el.remove();
                    }
                });
                document.querySelectorAll('div[style*="position: fixed"]').forEach(el => {
                    if (el.style.zIndex > 900 && el.innerHTML.length < 300) {
                        el.remove();
                    }
                });
                document.querySelectorAll('[class*="float"]').forEach(el => el.remove());
            }
            
            var pending = false; var observer = new MutationObserver(function() { if (pending) return; pending = true; requestAnimationFrame(function() { pending = false; cleanPage(); }); });
            observer.observe(document, { childList: true, subtree: true });
            document.addEventListener('DOMContentLoaded', cleanPage);
            setInterval(cleanPage, 3000);
        })();
        """
    }
}
