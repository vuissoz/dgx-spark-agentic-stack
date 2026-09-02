#!/usr/bin/env python3
"""Patch OpenHands 1.3's V1 Changes client to use the same-origin bridge.

The upstream bundle is intentionally patched at image build time because the
base image ships compiled frontend assets only.  Keep this replacement exact:
if OpenHands changes its bundle, fail the build instead of silently deploying
a broken or partially patched Changes panel.
"""

from __future__ import annotations

from pathlib import Path
import sys


ASSETS_DIR = Path('/app/frontend/build/assets')
OLD = """class t4{static buildRuntimeUrl(t,s){return`${zu(t)}${s}`}static async getGitChanges(t,s,i){const r=encodeURIComponent(i),n=this.buildRuntimeUrl(t,`/api/git/changes/${r}`),o=ya(s),{data:l}=await Sa.get(n,{headers:o});if(!Array.isArray(l))throw new Error("Invalid response from runtime - runtime may be unavailable");return l.map(a=>({status:e4(a.status),path:a.path}))}static async getGitChangeDiff(t,s,i){const r=encodeURIComponent(i),n=this.buildRuntimeUrl(t,`/api/git/diff/${r}`),o=ya(s),{data:l}=await Sa.get(n,{headers:o});return l}}"""
NEW = """class t4{static buildV1BridgeUrl(t,s){const i=new URL(t,window.location.origin),r=i.pathname.match(/^\\/api\\/conversations\\/([^/]+)$/);if(!r)throw new Error("Invalid V1 conversation URL");return`/api/v1/app-conversations/${encodeURIComponent(r[1])}${s}`}static async getGitChanges(t,s,i){const r=encodeURIComponent(i),n=this.buildV1BridgeUrl(t,`/git/changes?path=${r}`),{data:o}=await Sa.get(n);if(!Array.isArray(o))throw new Error("Invalid response from runtime - runtime may be unavailable");return o.map(l=>({status:e4(l.status),path:l.path}))}static async getGitChangeDiff(t,s,i){const r=encodeURIComponent(i),n=this.buildV1BridgeUrl(t,`/git/diff?path=${r}`),{data:o}=await Sa.get(n);return o}}"""


def main() -> int:
    candidates = sorted(ASSETS_DIR.glob('conversation-*.js'))
    matches = [
        bundle
        for bundle in candidates
        if bundle.read_text(encoding='utf-8').count(OLD) == 1
    ]
    if len(matches) != 1:
        raise RuntimeError(
            'OpenHands frontend Git bridge signature drifted '
            f'(expected exactly one matching bundle, found {matches})'
        )

    bundle = matches[0]
    content = bundle.read_text(encoding='utf-8')
    bundle.write_text(content.replace(OLD, NEW), encoding='utf-8')
    print(f'patched OpenHands V1 Git bridge in {bundle}')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f'error: {exc}', file=sys.stderr)
        raise SystemExit(1)
