import { useState, html, render } from "https://esm.sh/htm@3.1.1/preact/standalone";

const App = () => {
  const [result, setResult] = useState(null);

  const handleClick = async () => {
    const res = await fetch("/api/hello");
    setResult(await res.text());
  };

  return html`
    <div>
      <h1 class="text-2xl font-bold">Hello, world!</h1>

      <div class="mt-6">
        <button
          class="bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded"
          onClick=${handleClick}
        >
          Call API
        </button>
      </div>

      ${result && html`
        <div class="mt-8">
          <h2 class="text-lg font-semibold">Result</h2>
          <pre class="bg-neutral-200 p-2">${JSON.stringify({ result })}</pre>
        </div>
      `}
    </div>
  `;
};

render(html`<${App} />`, document.getElementById("app"));
