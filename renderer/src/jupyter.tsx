import { useEffect, useMemo, useRef, useState } from 'react'
import { HTMLManager } from '@jupyter-widgets/html-manager'
import type { ICallbacks, IClassicComm } from '@jupyter-widgets/base'
import { Sanitizer } from '@jupyterlab/apputils'
import {
  RenderMimeRegistry,
  standardRendererFactories,
} from '@jupyterlab/rendermime'
import type { IRenderMime } from '@jupyterlab/rendermime-interfaces'
import type { KernelMessage } from '@jupyterlab/services'
import type { JSONObject, JSONValue } from '@lumino/coreutils'
import { Widget } from '@lumino/widgets'
import katex from 'katex'
import { marked } from 'marked'
import '@lumino/widgets/style/index.css'
import '@jupyterlab/rendermime/style/base.css'
import '@jupyter-widgets/controls/css/widgets-base.css'
import 'katex/dist/katex.min.css'

/* oxlint-disable react/only-export-components -- Render hosts share stateful Jupyter registries. */

export type MimeBundle = Record<string, JSONValue>

export type JupyterEvent = {
  type: string
  requestId?: string
  content?: Record<string, unknown>
  header?: Record<string, unknown>
  parent_header?: Record<string, unknown>
  metadata?: JSONObject
  buffers?: string[]
  code?: string
}

type CommRequest = {
  type: 'comm_open' | 'comm_msg' | 'comm_close'
  message_id: string
  comm_id: string
  target_name?: string
  data: JSONValue
  metadata: JSONObject
  buffers: string[]
}

function encodeBuffer(buffer: ArrayBuffer | ArrayBufferView) {
  const bytes = buffer instanceof ArrayBuffer
    ? new Uint8Array(buffer)
    : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength)
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return window.btoa(binary)
}

function decodeBuffer(buffer: string) {
  const binary = window.atob(buffer)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes.buffer
}

class BrowserComm implements IClassicComm {
  readonly comm_id: string
  readonly target_name: string
  private readonly sendRequest: (request: CommRequest) => void
  private messageCallback?: (message: KernelMessage.ICommMsgMsg) => void
  private closeCallback?: (message: KernelMessage.ICommCloseMsg) => void
  private readonly callbacks = new Map<string, ICallbacks>()

  constructor(
    commId: string,
    targetName: string,
    sendRequest: (request: CommRequest) => void,
  ) {
    this.comm_id = commId
    this.target_name = targetName
    this.sendRequest = sendRequest
  }

  open(
    data: JSONValue,
    callbacks: ICallbacks = {},
    metadata: JSONObject = {},
    buffers: ArrayBuffer[] | ArrayBufferView[] = [],
  ) {
    return this.publish('comm_open', data, callbacks, metadata, buffers)
  }

  send(
    data: JSONValue,
    callbacks: ICallbacks = {},
    metadata: JSONObject = {},
    buffers: ArrayBuffer[] | ArrayBufferView[] = [],
  ) {
    return this.publish('comm_msg', data, callbacks, metadata, buffers)
  }

  close(
    data: JSONValue = {},
    callbacks: ICallbacks = {},
    metadata: JSONObject = {},
    buffers: ArrayBuffer[] | ArrayBufferView[] = [],
  ) {
    return this.publish('comm_close', data, callbacks, metadata, buffers)
  }

  on_msg(callback: (message: KernelMessage.ICommMsgMsg) => void) {
    this.messageCallback = callback
  }

  on_close(callback: (message: KernelMessage.ICommCloseMsg) => void) {
    this.closeCallback = callback
  }

  handleMessage(message: KernelMessage.ICommMsgMsg) {
    this.messageCallback?.(message)
  }

  handleClose(message: KernelMessage.ICommCloseMsg) {
    this.closeCallback?.(message)
  }

  handleRelated(message: JupyterEvent) {
    const parentId = message.parent_header?.msg_id
    if (typeof parentId !== 'string') return
    const callbacks = this.callbacks.get(parentId)
    const callback = callbacks?.iopub?.[message.type]
    const callbackMessage = {
      ...message,
      channel: 'iopub',
      buffers: message.buffers?.map(decodeBuffer) ?? [],
    } as unknown as KernelMessage.IIOPubMessage
    callback?.(callbackMessage)
    if (message.type === 'status'
      && message.content?.execution_state === 'idle') {
      this.callbacks.delete(parentId)
    }
  }

  private publish(
    type: CommRequest['type'],
    data: JSONValue,
    callbacks: ICallbacks,
    metadata: JSONObject,
    buffers: ArrayBuffer[] | ArrayBufferView[],
  ) {
    const messageId = window.crypto.randomUUID()
    this.callbacks.set(messageId, callbacks)
    this.sendRequest({
      type,
      message_id: messageId,
      comm_id: this.comm_id,
      target_name: type === 'comm_open' ? this.target_name : undefined,
      data,
      metadata,
      buffers: buffers.map(encodeBuffer),
    })
    return messageId
  }
}

export class BrowserWidgetManager extends HTMLManager {
  private readonly commUrl: string
  readonly interactive: boolean
  private readonly capability?: string
  private readonly comms = new Map<string, BrowserComm>()
  private sendChain = Promise.resolve()

  constructor(commUrl: string, capability?: string) {
    super()
    this.commUrl = commUrl
    this.capability = capability
    this.interactive = capability !== undefined
  }

  handleEvent(event: JupyterEvent) {
    for (const comm of this.comms.values()) comm.handleRelated(event)
    const commId = event.content?.comm_id
    if (typeof commId !== 'string') return

    if (event.type === 'comm_open') {
      const targetName = event.content?.target_name
      if (targetName !== this.comm_target_name) return
      const data = event.content?.data
      if (!isJSONObject(data)) {
        console.error('Widget comm_open event has invalid data')
        return
      }
      const comm = new BrowserComm(commId, targetName, this.sendRequest)
      this.comms.set(commId, comm)
      const message = {
        channel: 'iopub',
        header: event.header ?? {},
        parent_header: event.parent_header ?? {},
        metadata: event.metadata ?? {},
        content: {
          comm_id: commId,
          target_name: targetName,
          data,
        },
        buffers: event.buffers?.map(decodeBuffer) ?? [],
      } as unknown as KernelMessage.ICommOpenMsg
      void this.handle_comm_open(comm, message).catch((error: unknown) => {
        console.error('Could not open widget comm', error)
      })
    } else if (event.type === 'comm_msg') {
      this.comms.get(commId)?.handleMessage(
        this.asCommMessage(event) as KernelMessage.ICommMsgMsg,
      )
    } else if (event.type === 'comm_close') {
      this.comms.get(commId)?.handleClose(
        this.asCommMessage(event) as KernelMessage.ICommCloseMsg,
      )
      this.comms.delete(commId)
    }
  }

  override _create_comm(
    targetName: string,
    modelId: string,
    data: JSONValue = {},
    metadata: JSONObject = {},
    buffers: ArrayBuffer[] | ArrayBufferView[] = [],
  ) {
    const comm = new BrowserComm(modelId, targetName, this.sendRequest)
    this.comms.set(modelId, comm)
    comm.open(data, {}, metadata, buffers)
    return Promise.resolve(comm)
  }

  private readonly sendRequest = (request: CommRequest) => {
    if (!this.capability) return
    const pending = this.sendChain.then(async () => {
      const response = await fetch(this.commUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Jupyter-Eval-Capability': this.capability!,
        },
        body: JSON.stringify(request),
      })
      if (!response.ok) throw new Error(`Comm bridge returned HTTP ${response.status}`)
    })
    this.sendChain = pending.catch((error: unknown) => {
      console.error('Could not send widget comm message', error)
    })
  }

  private asCommMessage(event: JupyterEvent) {
    return {
      ...event,
      channel: 'iopub',
      buffers: event.buffers?.map(decodeBuffer) ?? [],
    } as unknown as KernelMessage.ICommMsgMsg | KernelMessage.ICommCloseMsg
  }
}

function isJSONObject(value: unknown): value is JSONObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

const latexTypesetter = {
  typeset(element: HTMLElement) {
    if (element.classList.contains('jp-RenderedLatex')) {
      const source = element.textContent ?? ''
      const latex = source.startsWith('$$') && source.endsWith('$$')
        ? source.slice(2, -2)
        : source.startsWith('$') && source.endsWith('$')
          ? source.slice(1, -1)
          : source
      katex.render(latex, element, {
        displayMode: true,
        throwOnError: false,
      })
      return
    }
    for (const script of element.querySelectorAll<HTMLScriptElement>(
      'script[type^="math/tex"]',
    )) {
      const host = document.createElement('span')
      katex.render(script.textContent ?? '', host, {
        displayMode: script.type.includes('mode=display'),
        throwOnError: false,
      })
      script.replaceWith(host)
    }
  },
}

class VideoSanitizer extends Sanitizer {
  constructor() {
    super()
    this.patchAllowedAttributes()
  }

  private patchAllowedAttributes() {
    const options = (this as unknown as { _options?: { allowedAttributes?: Record<string, string[]> } })._options
    if (options?.allowedAttributes) {
      options.allowedAttributes.source = Array.from(new Set([
        ...(options.allowedAttributes.source ?? []),
        'src',
        'type',
        'media',
      ]))
      options.allowedAttributes.video = Array.from(new Set([
        ...(options.allowedAttributes.video ?? []),
        'playsinline',
        'webkit-playsinline',
      ]))
      options.allowedAttributes.track = Array.from(new Set([
        ...(options.allowedAttributes.track ?? []),
        'src',
      ]))
    }
  }

  override setAllowedSchemes(scheme: Array<string>): void {
    super.setAllowedSchemes(scheme)
    this.patchAllowedAttributes()
  }

  override sanitize(dirty: string, options?: IRenderMime.ISanitizerOptions): string {
    if (options?.allowedAttributes) {
      options.allowedAttributes.source = Array.from(new Set([
        ...(options.allowedAttributes.source ?? []),
        'src',
        'type',
        'media',
      ]))
      options.allowedAttributes.video = Array.from(new Set([
        ...(options.allowedAttributes.video ?? []),
        'playsinline',
        'webkit-playsinline',
      ]))
      options.allowedAttributes.track = Array.from(new Set([
        ...(options.allowedAttributes.track ?? []),
        'src',
      ]))
    }
    return super.sanitize(dirty, options)
  }
}

const renderMime = new RenderMimeRegistry({
  initialFactories: standardRendererFactories,
  sanitizer: new VideoSanitizer(),
  markdownParser: {
    async render(source) {
      return await marked.parse(source)
    },
  },
  latexTypesetter,
})

function sanitizedBundle(data: MimeBundle, mimeType: string) {
  if (mimeType !== 'image/svg+xml' || typeof data[mimeType] !== 'string') {
    return { data, trusted: false }
  }

  const document = new DOMParser().parseFromString(
    data[mimeType] as string,
    'image/svg+xml',
  )
  if (document.querySelector('parsererror')) {
    throw new Error('The SVG output is not valid XML.')
  }
  document.querySelectorAll(
    'script, foreignObject, iframe, object, embed, style',
  ).forEach((element) => element.remove())
  for (const element of document.querySelectorAll('*')) {
    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase()
      const value = attribute.value.trim().toLowerCase()
      if (name.startsWith('on')
        || name === 'style'
        || ((name === 'href' || name === 'xlink:href')
          && !value.startsWith('#')
          && !value.startsWith('data:image/'))) {
        element.removeAttribute(attribute.name)
      }
    }
  }
  return {
    data: {
      ...data,
      [mimeType]: new XMLSerializer().serializeToString(document.documentElement),
    },
    trusted: true,
  }
}

export function MimeOutput({
  data,
  metadata = {},
}: {
  data: MimeBundle
  metadata?: JSONObject
}) {
  const host = useRef<HTMLDivElement>(null)
  const [renderError, setRenderError] = useState('')
  const prepared = useMemo<{
    ok: false
    error: string
  } | {
    ok: true
    mimeType: string
    data: MimeBundle
    trusted: boolean
  }>(() => {
    const mimeType = typeof data['image/svg+xml'] === 'string'
      ? 'image/svg+xml'
      : renderMime.preferredMimeType(data, 'ensure')
    if (!mimeType) {
      return { ok: false, error: 'No safe renderer is available for this output.' }
    }
    try {
      return { ok: true, mimeType, ...sanitizedBundle(data, mimeType) }
    } catch (error) {
      return {
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      }
    }
  }, [data])

  useEffect(() => {
    if (!host.current || !prepared.ok) return
    const renderer = renderMime.createRenderer(prepared.mimeType)
    host.current.replaceChildren()
    Widget.attach(renderer, host.current)
    void renderer.renderModel(renderMime.createModel({
      data: prepared.data,
      metadata,
      trusted: prepared.trusted,
    })).then(() => setRenderError('')).catch((error: unknown) => {
      setRenderError(error instanceof Error ? error.message : String(error))
    })
    return () => {
      if (renderer.isAttached) Widget.detach(renderer)
      renderer.dispose()
    }
  }, [metadata, prepared])

  const error = prepared.ok ? renderError : prepared.error
  return error
    ? <pre className="mime-error">{error}</pre>
    : <div className="mime-output" ref={host} />
}

export function WidgetOutput({
  manager,
  modelId,
}: {
  manager: BrowserWidgetManager
  modelId: string
}) {
  const host = useRef<HTMLDivElement>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    let disposed = false
    let view: Awaited<ReturnType<BrowserWidgetManager['create_view']>> | undefined
    void manager.get_model(modelId)
      .then((model) => manager.create_view(model))
      .then(async (createdView) => {
        view = createdView
        if (disposed || !host.current) {
          createdView.remove()
          return
        }
        await manager.display_view(createdView, host.current)
      })
      .catch((viewError: unknown) => {
        if (!disposed) {
          setError(viewError instanceof Error ? viewError.message : String(viewError))
        }
      })
    return () => {
      disposed = true
      view?.remove()
    }
  }, [manager, modelId])

  return error
    ? <pre className="mime-error">{error}</pre>
    : <div
        aria-disabled={!manager.interactive}
        className={`widget-output ${manager.interactive ? '' : 'read-only'}`}
        ref={(element) => {
          host.current = element
          if (element) element.inert = !manager.interactive
        }}
      />
}
