import { h, render, Component } from 'preact';

interface Result {
  id: string
  method: string
  urlPath: string
  durationMs: number
}

interface Options {
  path: string
}

type XhrOpenListener = (xhr: XMLHttpRequest) => void
const xhrOpenListeners: XhrOpenListener[] = []
function addXhrOpenListener(cb: XhrOpenListener) {
  xhrOpenListeners.push(cb)
}
const realOpen = XMLHttpRequest.prototype.open
XMLHttpRequest.prototype.open = function(this: XMLHttpRequest, ...args: any[]) {
  const ret = realOpen.apply(this, args)
  xhrOpenListeners.forEach(f => f(this))
  return ret
}

function fetchResult(id: string, options: Options): Promise<Result> {
  return new Promise((resolve, reject) => {
    const req = new XMLHttpRequest
    req.addEventListener("load", () => {
      const response = JSON.parse(req.responseText)
      const root = response.root
      const name = root.name
      const [method, ...urlParts] = name.split(' ')
      const url = new URL(urlParts.join(' '))
      resolve({
        id: response.id as string,
        durationMs: root.duration_milliseconds as number,
        method: method as string,
        urlPath: url.pathname as string
      })
    })
    req.open("GET", `${options.path}results?id=${id}`)

    // This forces rack to recognize this as an xhr
    // See: https://apidock.com/rails/Rack/Request/xhr%3F
    // req.setRequestHeader('HTTP_X_REQUESTED_WITH', 'XMLHttpRequest')
    req.setRequestHeader('X-Requested-With', 'XMLHttpRequest')
    req.send()
  })
}

function getOptions(script: HTMLScriptElement) {
  const version = script.getAttribute('data-version')!;
  const path = script.getAttribute('data-path')!;

  const currentId = script.getAttribute('data-current-id')!;

  const ids = (script.getAttribute('data-ids') || '').split(',')

  const horizontalPosition = script.getAttribute('data-horizontal-position');
  const verticalPosition = script.getAttribute('data-vertical-position');
  const toggleShortcut = script.getAttribute('data-toggle-shortcut');
  const collapseResults = script.getAttribute('data-collapse-results') === 'true';
  const trivial = script.getAttribute('data-trivial') === 'true';
  const children = script.getAttribute('data-children') === 'true';
  const controls = script.getAttribute('data-controls') === 'true';
  const authorized = script.getAttribute('data-authorized') === 'true';
  const startHidden = script.getAttribute('data-start-hidden') === 'true';
  const htmlContainer = script.getAttribute('data-html-container');

  return {
    ids: ids,
    path: path,
    version: version,
    renderHorizontalPosition: horizontalPosition,
    renderVerticalPosition: verticalPosition,
    showTrivial: trivial,
    showChildrenTime: children,
    showControls: controls,
    currentId: currentId,
    authorized: authorized,
    toggleShortcut: toggleShortcut,
    startHidden: startHidden,
    collapseResults: collapseResults,
    htmlContainer: htmlContainer
  };
}

class MiniProfiler extends Component<void, void> {
  componentDidMount() {
    const script = document.getElementById('mini-profiler');
    if (!script || !script.getAttribute) return;
    const options = getOptions(script as HTMLScriptElement)

    const resultById: {[key: string]: Promise<Result>} = Object.create(null)

    const results: Result[] = []

    function fetchResultOnce(id: string): Promise<Result> {
      if (!resultById[id]) {
        resultById[id] = fetchResult(id, options).then((result) => {
          results.push(result)
          render()
          return result
        })
      }
      return resultById[id]
    }

    addXhrOpenListener((xhr) => {
      xhr.addEventListener('load', () => {
        if (xhr.responseURL.indexOf(options.path) !== -1) return
        const ids = xhr.getResponseHeader('X-MiniProfiler-Ids')
        if (ids) {
          const idList: string[] = JSON.parse(ids)
          idList.forEach(fetchResultOnce)
        }
      })
    })
    fetchResultOnce(options.currentId)
  }

  render() {
    return null
  }
}

render(<MiniProfiler />, document.body)