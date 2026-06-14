// Spotify control dispatcher (JXA — run via `osascript -l JavaScript spotify.js <cmd> [arg]`).
//
// Why JXA and not `kind:"media"`: the system media keys (what nowplaying uses)
// drive whatever app last grabbed Now-Playing, not Spotify specifically. Spotify's
// public AppleScript dictionary lets us target it directly and read real state
// (track, volume, shuffle, repeat) as JSON — which a media-key tile can't.
//
// Guard: never send an AppleEvent to Spotify unless it's already running, otherwise
// AppleScript silently LAUNCHES Spotify just to answer a poll. We check NSWorkspace
// (no AppleEvent) before touching the app bridge.

ObjC.import('AppKit');

function spotifyRunning() {
  const apps = $.NSWorkspace.sharedWorkspace.runningApplications;
  for (let i = 0; i < apps.count; i++) {
    if (ObjC.unwrap(apps.objectAtIndex(i).bundleIdentifier) === 'com.spotify.client') return true;
  }
  return false;
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

function run(argv) {
  const cmd = argv[0] || 'getstate';
  const arg = argv[1];

  // State reads must degrade gracefully when Spotify is closed — the tile polls
  // this every few seconds and must not be the thing that boots Spotify.
  if (!spotifyRunning()) {
    if (cmd === 'getstate') return JSON.stringify({ state: 'stopped', running: false });
    if (cmd === 'getvolume') return '';
    return ''; // transport commands no-op when not running
  }

  const sp = Application('Spotify');

  switch (cmd) {
    case 'play':       sp.play();       return '';
    case 'pause':      sp.pause();      return '';
    case 'playpause':  sp.playpause();  return '';
    case 'next':       sp.nextTrack();  return '';
    case 'previous':   sp.previousTrack(); return '';

    case 'getvolume':  return String(sp.soundVolume());
    case 'setvolume':  sp.soundVolume = clamp(parseInt(arg, 10) || 0, 0, 100); delay(0.05); return String(sp.soundVolume());
    case 'changevolume': {
      const next = clamp(sp.soundVolume() + (parseInt(arg, 10) || 0), 0, 100);
      sp.soundVolume = next; delay(0.05); return String(sp.soundVolume());
    }

    case 'setshuffling': sp.shuffling = (arg === 'toggle') ? !sp.shuffling() : (arg === 'true'); return String(sp.shuffling());
    case 'setrepeating': sp.repeating = (arg === 'toggle') ? !sp.repeating() : (arg === 'true'); return String(sp.repeating());

    case 'skipbyseconds': sp.playerPosition = Math.max(0, sp.playerPosition() + (parseInt(arg, 10) || 0)); return '';

    case 'getstate': {
      const state = ObjC.unwrap(sp.playerState());     // 'playing' | 'paused' | 'stopped'
      let t = {};
      try {
        const ct = sp.currentTrack;
        t = {
          name: ct.name(), artist: ct.artist(), album: ct.album(),
          duration: ct.duration(), artworkUrl: ct.artworkUrl(),
          spotifyUrl: ct.spotifyUrl(),
        };
      } catch (e) { /* no track loaded */ }
      const pos = Math.round(sp.playerPosition());
      const fmt = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
      return JSON.stringify({
        running: true,
        state,
        name: t.name || '—',
        artist: t.artist || '',
        album: t.album || '',
        position: t.duration ? `${fmt(pos)} / ${fmt(Math.round(t.duration / 1000))}` : fmt(pos),
        volume: sp.soundVolume(),
        shuffling: sp.shuffling(),
        repeating: sp.repeating(),
        artworkUrl: t.artworkUrl || '',
        spotifyUrl: t.spotifyUrl || '',
      });
    }

    default: return JSON.stringify({ error: `unknown command: ${cmd}` });
  }
}
