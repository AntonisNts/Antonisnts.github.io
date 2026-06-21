# Project working agreement

## PR / deployment workflow (set by repo owner)

Two-stage deploy via a `staging` branch. Changes are tested on staging before
they reach production.

- **Each change goes on its own feature branch**, then a PR with
  **base = `staging`** (not `main`).
- **Do not merge without explicit approval.** Wait until the owner says "merge."
- Merging into **`staging`** auto-deploys to the staging site
  **https://paystamp-staging.netlify.app** (Netlify watches the `staging`
  branch) for manual testing.
- Once verified, **promote by merging `staging` → `main`**. GitHub Pages serves
  `main` ("deploy from branch") at the custom domain **paystamp.app**, so changes
  only go live in production after `staging` reaches `main`.
- **The two deploys are independent:** Netlify builds only `staging`; GitHub
  Pages builds only `main`. Do not change the Pages "deploy from branch" setting
  or the `CNAME` (paystamp.app), and do not add a Pages Actions workflow — that
  would disturb production.
- If `main` ever gets a direct hotfix, sync it back: `git checkout staging &&
  git merge main && git push`.

## App build note

- `index.html` is a single-file React app (React + Babel + Supabase from CDN,
  no build step) — it is the deployed artifact.
- Student PINs are intentionally plain text (teacher-assigned, shareable codes).
- Backend schema + setup live in `supabase/`.
