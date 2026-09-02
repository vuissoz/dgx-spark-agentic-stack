# IMPORTANT: LEGACY V0 CODE - Deprecated since version 1.0.0, scheduled for removal April 1, 2026
# This file is part of the legacy (V0) implementation of OpenHands and will be removed soon as we complete the migration to V1.
# OpenHands V1 uses the Software Agent SDK for the agentic core and runs a new application server. Please refer to:
#   - V1 agentic core (SDK): https://github.com/OpenHands/software-agent-sdk
#   - V1 application server (in this repo): openhands/app_server/
# Unless you are working on deprecation, please avoid extending this legacy file and consult the V1 codepaths above.
# Tag: Legacy-V0
# This module belongs to the old V0 web server. The V1 application server lives under openhands/app_server/.
import asyncio
import os
from urllib.parse import urlencode, urlparse, urlunparse

import httpx
import socketio
from fastapi import Depends, HTTPException, Query, Request, WebSocket, status
from starlette.websockets import WebSocketState
from websockets.asyncio.client import connect as ws_connect
from websockets.exceptions import ConnectionClosed

from openhands.app_server.config import (
    get_global_config,
)
from openhands.core.logger import openhands_logger as logger
from openhands.server.app import app as base_app
from openhands.server.listen_socket import sio
from openhands.server.middleware import (
    CacheControlMiddleware,
    InMemoryRateLimiter,
    LocalhostCORSMiddleware,
    RateLimitMiddleware,
)
from openhands.server.routes.conversation import _resolve_v1_runtime_endpoint
from openhands.server.static import SPAStaticFiles


async def _depends_ws_app_conversation_service(websocket: WebSocket):
    injector = get_global_config().app_conversation
    assert injector is not None
    async for service in injector.inject(websocket.state, websocket):
        yield service


async def _depends_ws_app_conversation_start_task_service(websocket: WebSocket):
    injector = get_global_config().app_conversation_start_task
    assert injector is not None
    async for service in injector.inject(websocket.state, websocket):
        yield service


async def _depends_http_app_conversation_service(request: Request):
    """Inject the V1 conversation service for same-origin HTTP bridges."""
    injector = get_global_config().app_conversation
    assert injector is not None
    async for service in injector.inject(request.state, request):
        yield service


async def _depends_http_app_conversation_start_task_service(request: Request):
    """Inject the V1 start-task service for same-origin HTTP bridges."""
    injector = get_global_config().app_conversation_start_task
    assert injector is not None
    async for service in injector.inject(request.state, request):
        yield service


def _build_runtime_events_ws_url(
    conversation_url: str,
    conversation_id: str,
    session_api_key: str | None,
    resend_all: bool,
) -> str:
    parsed = urlparse(conversation_url)
    scheme = 'wss' if parsed.scheme == 'https' else 'ws'
    path_root = parsed.path.split('/api/conversations', 1)[0].rstrip('/')
    path = f'{path_root}/sockets/events/{conversation_id}'
    query: dict[str, str] = {}
    if session_api_key:
        query['session_api_key'] = session_api_key
    if resend_all:
        query['resend_all'] = 'true'
    return urlunparse((scheme, parsed.netloc, path, '', urlencode(query), ''))


def _build_runtime_http_url(conversation_url: str, runtime_path: str) -> str:
    """Build an agent-server URL from a V1 conversation endpoint.

    ``_resolve_v1_runtime_endpoint`` returns a conversation-scoped URL.  Git
    operations live on the agent-server root, so preserve only the runtime
    origin and any path prefix preceding ``/api/conversations``.
    """
    parsed = urlparse(conversation_url)
    path_root = parsed.path.split('/api/conversations', 1)[0].rstrip('/')
    return urlunparse(
        (parsed.scheme, parsed.netloc, f'{path_root}{runtime_path}', '', '', '')
    )


def _validate_workspace_path(path: str) -> str:
    """Keep the bridge scoped to the workspace mounted into ProcessSandbox."""
    if not path.startswith('/workspace/') or '..' in path.split('/'):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail='workspace path must stay below /workspace',
        )
    return path


async def _forward_v1_git_request(
    conversation_id: str,
    runtime_path: str,
    app_conversation_service,
    app_conversation_start_task_service,
    expected_type: type,
) -> list | dict:
    """Forward a Git read request to a V1 runtime without exposing its port."""
    resolved = await _resolve_v1_runtime_endpoint(
        conversation_id,
        app_conversation_service,
        app_conversation_start_task_service,
    )
    if resolved is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f'Conversation {conversation_id} not found',
        )

    conversation_url, session_api_key = resolved
    headers: dict[str, str] = {}
    if session_api_key:
        headers['X-Session-API-Key'] = session_api_key
    runtime_url = _build_runtime_http_url(conversation_url, runtime_path)

    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(runtime_url, headers=headers, timeout=30.0)
    except httpx.HTTPError as exc:
        logger.warning(
            'V1 Git bridge cannot reach runtime for conversation %s: %s',
            conversation_id,
            exc,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail='V1 runtime is unavailable; retry after the conversation is ready',
        ) from exc

    if response.status_code >= 400:
        logger.warning(
            'V1 Git bridge runtime request failed for conversation %s: status=%s',
            conversation_id,
            response.status_code,
        )
        raise HTTPException(
            status_code=response.status_code,
            detail='V1 runtime rejected the Git request',
        )

    try:
        payload = response.json()
    except ValueError as exc:
        logger.warning(
            'V1 Git bridge received non-JSON payload for conversation %s',
            conversation_id,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail='V1 runtime returned an invalid Git response',
        ) from exc

    if not isinstance(payload, expected_type):
        logger.warning(
            'V1 Git bridge received unexpected payload type for conversation %s',
            conversation_id,
        )
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail='V1 runtime returned an invalid Git response',
        )
    return payload


@base_app.get('/api/v1/app-conversations/{conversation_id}/git/changes')
async def bridge_v1_git_changes(
    conversation_id: str,
    path: str = Query('/workspace/project'),
    app_conversation_service=Depends(_depends_http_app_conversation_service),
    app_conversation_start_task_service=Depends(
        _depends_http_app_conversation_start_task_service
    ),
) -> list:
    """Return V1 runtime Git changes through the public OpenHands origin."""
    workspace_path = _validate_workspace_path(path)
    return await _forward_v1_git_request(
        conversation_id,
        f'/api/git/changes/{workspace_path}',
        app_conversation_service,
        app_conversation_start_task_service,
        list,
    )


@base_app.get('/api/v1/app-conversations/{conversation_id}/git/diff')
async def bridge_v1_git_diff(
    conversation_id: str,
    path: str = Query(...),
    app_conversation_service=Depends(_depends_http_app_conversation_service),
    app_conversation_start_task_service=Depends(
        _depends_http_app_conversation_start_task_service
    ),
) -> dict:
    """Return a V1 runtime Git diff through the public OpenHands origin."""
    file_path = _validate_workspace_path(path)
    return await _forward_v1_git_request(
        conversation_id,
        f'/api/git/diff/{file_path}',
        app_conversation_service,
        app_conversation_start_task_service,
        dict,
    )


async def _proxy_websocket_traffic(
    client_websocket: WebSocket,
    runtime_websocket,
) -> None:
    async def runtime_to_client() -> None:
        async for payload in runtime_websocket:
            if isinstance(payload, bytes):
                await client_websocket.send_bytes(payload)
            else:
                await client_websocket.send_text(payload)

    async def client_to_runtime() -> None:
        while True:
            message = await client_websocket.receive()
            message_type = message.get('type')
            if message_type == 'websocket.disconnect':
                return
            if message_type != 'websocket.receive':
                continue
            text_payload = message.get('text')
            bytes_payload = message.get('bytes')
            if text_payload is not None:
                await runtime_websocket.send(text_payload)
            elif bytes_payload is not None:
                await runtime_websocket.send(bytes_payload)

    runtime_to_client_task = asyncio.create_task(runtime_to_client())
    client_to_runtime_task = asyncio.create_task(client_to_runtime())
    done, pending = await asyncio.wait(
        {runtime_to_client_task, client_to_runtime_task},
        return_when=asyncio.FIRST_COMPLETED,
    )
    for task in pending:
        task.cancel()
    await asyncio.gather(*pending, return_exceptions=True)
    for task in done:
        exception = task.exception()
        if exception is not None:
            raise exception


@base_app.websocket('/sockets/events/{conversation_id}')
async def bridge_v1_events_socket(
    conversation_id: str,
    websocket: WebSocket,
    resend_all: bool = False,
    app_conversation_service=Depends(_depends_ws_app_conversation_service),
    app_conversation_start_task_service=Depends(
        _depends_ws_app_conversation_start_task_service
    ),
) -> None:
    try:
        resolved = await _resolve_v1_runtime_endpoint(
            conversation_id,
            app_conversation_service,
            app_conversation_start_task_service,
        )
    except HTTPException as exc:
        # V1 runtime startup is still in progress.
        if exc.status_code == status.HTTP_409_CONFLICT:
            await websocket.close(code=4409, reason='runtime_not_ready')
            return
        await websocket.close(code=1011, reason='runtime_resolution_failed')
        return

    if resolved is None:
        await websocket.close(code=4404, reason='conversation_not_found')
        return

    conversation_url, session_api_key = resolved
    runtime_ws_url = _build_runtime_events_ws_url(
        conversation_url=conversation_url,
        conversation_id=conversation_id,
        session_api_key=session_api_key,
        resend_all=resend_all,
    )

    try:
        async with ws_connect(runtime_ws_url, open_timeout=10, close_timeout=5) as runtime_ws:
            await websocket.accept()
            await _proxy_websocket_traffic(websocket, runtime_ws)
    except ConnectionClosed:
        if websocket.application_state != WebSocketState.DISCONNECTED:
            await websocket.close(code=1000)
    except Exception as exc:
        logger.error(
            'Error proxying V1 websocket events for %s via %s: %s',
            conversation_id,
            runtime_ws_url,
            exc,
        )
        if websocket.application_state != WebSocketState.DISCONNECTED:
            await websocket.close(code=1011, reason='runtime_bridge_failed')


if os.getenv('SERVE_FRONTEND', 'true').lower() == 'true':
    base_app.mount(
        '/', SPAStaticFiles(directory='./frontend/build', html=True), name='dist'
    )

base_app.add_middleware(LocalhostCORSMiddleware)
base_app.add_middleware(CacheControlMiddleware)
base_app.add_middleware(
    RateLimitMiddleware,
    rate_limiter=InMemoryRateLimiter(requests=10, seconds=1),
)

app = socketio.ASGIApp(sio, other_asgi_app=base_app)
