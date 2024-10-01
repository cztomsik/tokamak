import { useState, useEffect, html, render } from "https://esm.sh/htm@3.1.1/preact/standalone"

const App = () => {
  const [path, setPath] = useState(location.hash.slice(1))
  useEffect(() => addEventListener("hashchange", () => setPath(location.hash.slice(1))), [])

  return html`
    <div class="overflow-hidden rounded-lg border shadow-lg">
      <div class="bg-gray-100 px-8 py-5 border-b">
        <ul class="flex items-center justify-center gap-5 font-medium">
          <h1 class="text-lg font-semibold">My Blog</h1>
          <a href="/swagger-ui" class="text-blue-500">Swagger UI</a>
        </ul>
      </div>
      <div class="text-center p-8">${path ? html`<${EditPost} id=${+path} />` : html`<${Posts} />`}</div>
    </div>
  `
}

const Posts = () => {
  const [posts, setPosts] = useState(null)
  useEffect(() => void refetch(), [])

  const refetch = () =>
    fetch("/api/posts")
      .then(res => res.json())
      .then(setPosts)

  const handleDelete = async id => {
    await fetch(`/api/posts/${id}`, { method: "DELETE" })
    await refetch()
  }

  return html`
    <div>
      <h1 class="text-4xl font-bold">Posts</h1>

      <ul class="mt-5">
        ${posts?.map(
          p => html`
            <li class="flex justify-between items-center border-b-1 py-3">
              <a href="#${p.id}" class="text-blue-500">${p.title}</a>
              <button class="text-red-500" onClick=${() => handleDelete(p.id)}>Delete</button>
            </li>
          `
        )}
      </ul>
    </div>
  `
}

const EditPost = ({ id }) => {
  const [post, setPost] = useState(null)
  useEffect(() => {
    fetch(`/api/posts/${id}`)
      .then(res => res.json())
      .then(setPost)
  }, [])

  const handleInput = e => {
    setPost({ ...post, [e.target.name]: e.target.value })
  }

  const handleSubmit = async e => {
    e.preventDefault()
    await fetch(`/api/posts/${id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(post),
    })
    location.hash = ""
  }

  return html`
    <div>
      <h1 class="text-4xl font-bold">Edit Post ${id}</h1>

      <form class="mt-5 text-left max-w-96 mx-auto" onSubmit=${handleSubmit}>
        <div class="mb-5">
          <label class="block mb-2 text-sm font-medium text-gray-900">Title</label>
          <input
            name="title"
            class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5"
            value=${post?.title}
            onInput=${handleInput}
          />
        </div>
        <div class="mb-5">
          <label class="block mb-2 text-sm font-medium text-gray-900">Body</label>
          <textarea
            name="body"
            rows="5"
            class="bg-gray-50 border border-gray-300 text-gray-900 text-sm rounded-lg focus:ring-blue-500 focus:border-blue-500 block w-full p-2.5"
            value=${post?.body}
            onInput=${handleInput}
          />
        </div>
        <button
          type="submit"
          class="text-white bg-blue-700 hover:bg-blue-800 focus:ring-4 focus:outline-none focus:ring-blue-300 font-medium rounded-lg text-sm w-full sm:w-auto px-5 py-2.5 text-center"
        >
          Submit
        </button>
      </form>
    </div>
  `
}

render(html`<${App} />`, document.getElementById("app"))
