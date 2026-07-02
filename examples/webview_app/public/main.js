import { useState, html, render } from "https://esm.sh/htm@3.1.1/preact/standalone";

let eventSource = null;

const App = () => {
  const [result, setResult] = useState(null);
  const [sseEvents, setSseEvents] = useState([]);

  const handleClick = async () => {
    const res = await fetch("/api/hello");
    setResult(await res.text());
  };

  const toggleSSE = () => {
    if (eventSource) {
      eventSource.close();
      eventSource = null;
    } else {
      eventSource = new EventSource("/api/sse");
      eventSource.onmessage = (e) => setSseEvents((prev) => [...prev.slice(-19), JSON.parse(e.data)]);
    }
  };

  return html`
    <div>
      <h1 class="text-2xl font-bold">Hello, world!</h1>

      <div class="mt-6 flex gap-4">
        <button
          class="bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded"
          onClick=${handleClick}
        >
          Call API
        </button>

        <button
          class="bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded"
          onClick=${toggleSSE}
        >
          Toggle SSE
        </button>
      </div>

      ${result && html`
        <div class="mt-8">
          <h2 class="text-lg font-semibold">Result</h2>
          <pre class="bg-neutral-200 p-2">${JSON.stringify({ result })}</pre>
        </div>
      `}

      ${sseEvents.length > 0 && html`
        <div class="mt-8">
          <pre class="bg-neutral-200 p-2 max-h-40 overflow-y-auto whitespace-pre-wrap">${sseEvents.map((e) => html`<div>${JSON.stringify(e)}</div>`)}</pre>
        </div>
      `}
    </div>
  `;
};

render(html`<${App} />`, document.getElementById("app"));
