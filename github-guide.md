# GitHub quick guide for our team

We use AI to operate Git. You still decide what to build, check the result, and coordinate with teammates.

## The basic words

| Word | What it means |
| --- | --- |
| Repository / repo | Our project files and their recorded history, shared through GitHub. |
| Clone | Your own local copy of the project. Everyone works in their own copy. |
| `main` | Our shared working version. Keep it runnable. |
| Branch | A separate line of work, such as camera UI or model evaluation. Changes stay separate from `main` until merged. |
| Commit | A saved checkpoint of selected changes in your branch. It is local until pushed. |
| Push | Send your commits to GitHub so others can see them. This does not merge them into `main`. |
| Pull | Bring changes from GitHub into your local copy. Other people's work does not appear automatically. |
| Pull request / PR | A proposal to merge one branch into another, usually into `main`. Teammates can review it first. |
| Merge | Combine the branch's changes into `main`. |
| Conflict | Changes Git cannot combine automatically. Agree on the intended result, then ask AI to help resolve it. |

## Our workflow

1. **Get access.** Accept the repository invitation with your own GitHub account. Ask AI to connect your account and clone this repo.
2. **Start a small task.** Agree who owns it. Ask AI to start a new branch from the latest `main`, preserving any existing work.
3. **Build and check it.** Use your AI normally. Ask it to commit useful checkpoints and push the branch to GitHub.
4. **Open a PR.** Ask AI to summarize what changed, how it was checked, and anything unfinished. Send the PR link to our integration owner.
5. **Review and merge.** The integration owner coordinates review and checks the combined result. iOS changes need a Mac build check and relevant device testing.
6. **Start the next task.** Once merged, ask AI to update your local `main` and create a fresh branch for the next milestone.

## What to tell your AI

**Starting:** “Read the project instructions. My task is [task], and I own [files / area]. Preserve existing work and create a task branch from the latest main. Coordinate before changing shared interfaces.”

**Sharing:** “Review my changes for this task, run the relevant checks, commit and push the intended files, and open a pull request into main. Explain what works and what still needs checking. Leave merging to our integration owner.”

**Updating ongoing work:** “Bring the latest main into my current branch without losing my changes. Explain any conflicts and check that the combined result works.”

## Team habits

- **Merge several small working milestones during the weekend.** The whole feature does not have to be finished: a camera screen using clearly marked sample results can be a useful milestone.
- **A branch is not a separate folder.** For simultaneous AI sessions on one computer, ask for separate worktrees, or give shared-workspace agents non-overlapping files. Do not switch branches underneath another active worker.
- **Git shares files, not AI memory.** Write important interfaces, decisions and setup instructions in the repo.
- **Save and push regularly.** Local edits and commits are not yet shared on GitHub.
- **Keep large datasets and model checkpoints outside ordinary Git.** Record the exact artifact version and approved download location instead.
- **This repo is public.** Do not commit credentials or restricted challenge data. Ask before force-pushing, deleting work, or changing someone else's active files.

Our loop: **latest main → task branch → build → commit and push → PR → review → merge → repeat.**
