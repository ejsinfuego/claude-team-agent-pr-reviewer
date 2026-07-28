import { Octokit } from "@octokit/rest";

export function createGithubClient(token) {
  const octokit = new Octokit({ auth: token });

  return {
    // Returns open, non-draft PRs for "owner/name" as [{ number, headSha }].
    async listOpenPrs(repo) {
      const [owner, name] = repo.split("/");
      const prs = await octokit.paginate(octokit.rest.pulls.list, {
        owner,
        repo: name,
        state: "open",
        per_page: 100,
      });

      return prs
        .filter((pr) => !pr.draft)
        .map((pr) => ({ number: pr.number, headSha: pr.head.sha }));
    },
  };
}
