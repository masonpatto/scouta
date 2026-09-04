# Scouta

A React Native (Expo) app for scouting and trading football (soccer) player cards. Players take a personality-driven quiz to get a scout archetype, earn virtual capital, then buy, hold, and sell player cards on a leaderboard against other users.

## Stack

- **Expo / React Native** (`expo` ~54, `react-native` 0.81, `react` 19)
- **Supabase** for auth and data, called directly via `fetch` (no SDK) — see `SUPABASE_URL` / `SUPABASE_ANON_KEY` at the top of `App.js`
- Single-file app: all screens and logic currently live in `App.js`, driven by local component state (no navigation library yet)

## Running locally

```
npm install
npm start        # then press i / a / w, or scan the QR code with Expo Go
```

## Structure

- `App.js` — entire app: auth, onboarding quiz, home/discover/portfolio/leaderboard tabs, player cards, capital/coin reveal animation
- `components/` — shared components
- `assets/` — app icons/splash (most in-app imagery, like the wordmark, blobs, and tier badges, is embedded as base64 data URIs directly in `App.js`)
