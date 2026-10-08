import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:http";

// Synthetic GitHub GraphQL responses. No real release or remote repository is changed.
export async function startGithubFixture(originalDigest, newDigest) {
  const publishedAt = "2020-01-01T00:00:00.000Z";
  const release = (version, extra = {}) => ({
    version, releaseTimestamp: publishedAt, isDraft: false, isPrerelease: false,
    url: `https://github.com/mmkolpakov/robotics-runtime/releases/tag/${version}`,
    id: null, name: null, description: null, ...extra,
  });
  const releases = [
    release("harness-v0.19.0"), release("harness-v0.20.0"),
    release("harness-v0.21.0", { isPrerelease: true }),
    release("harness-v0.22.0", { isDraft: true }),
    release("harness-v0.23.0", { releaseTimestamp: new Date().toISOString() }),
    release("harness-v0.24.0-rc.1"), release("contracts-v99.0.0"), release("v99.0.0"),
  ];
  const tags = [
    { version: "harness-v0.19.0", target: {
      type: "Commit", oid: originalDigest, releaseTimestamp: publishedAt,
    } },
    { version: "harness-v0.20.0", target: {
      type: "Tag", oid: "a".repeat(40), tagger: { releaseTimestamp: publishedAt },
      target: { type: "Commit", oid: newDigest },
    } },
    { version: "harness-v99.0.0", target: {
      type: "Commit", oid: "9".repeat(40), releaseTimestamp: publishedAt,
    } },
  ];
  const queries = [];
  const server = createServer(async (request, response) => {
    assert.equal(request.method, "POST");
    assert.equal(request.url, "/api/graphql");
    let content = "";
    for await (const chunk of request) content += chunk;
    const { query, variables } = JSON.parse(content);
    assert.equal(variables.owner, "mmkolpakov");
    assert.equal(variables.name, "robotics-runtime");
    assert.equal(variables.cursor, null);
    const kind = query.includes("releases(") ? "releases"
      : query.includes("refPrefix: \"refs/tags/\"") ? "tags" : undefined;
    assert.ok(kind, "unexpected GraphQL operation");
    queries.push(kind);
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({ data: { repository: { isRepoPrivate: false, payload: {
      nodes: kind === "releases" ? releases : tags,
      pageInfo: { hasNextPage: false, endCursor: null },
    } } } }));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    queries,
    close: () => new Promise((resolve, reject) => {
      server.closeAllConnections();
      server.close((error) => error ? reject(error) : resolve());
    }),
  };
}
