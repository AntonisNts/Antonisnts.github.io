# Project working agreement

## PR / deployment workflow (set by repo owner)

- **Batch all changes** onto the branch `claude/magic-stamp-app-UgXDO`.
- Keep a **single PR open** for this branch and push every new commit to it.
- **Do not open additional PRs and do not merge.** Wait until the owner
  explicitly says "merge."
- GitHub Pages serves `main`, so changes only go live after the owner merges.

## App build note

- `index.html` is a single-file React app (React + Babel + Supabase from CDN,
  no build step) — it is the deployed artifact.
- Student PINs are intentionally plain text (teacher-assigned, shareable codes).
- Backend schema + setup live in `supabase/`.
