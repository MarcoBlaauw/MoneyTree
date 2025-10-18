defmodule MoneyTreeWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for rendering HTML and LiveView content.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Plug.CSRFProtection

  # JS Commands
  def show(selector), do: show(%JS{}, selector)
  def show(js, selector), do: JS.show(js, to: selector)

  def hide(selector), do: hide(%JS{}, selector)
  def hide(js, selector), do: JS.hide(js, to: selector)

  ## Flash Components

  attr :flash, :map, default: %{}
  slot :inner_block, required: true

  def flash(assigns) do
    ~H"""
    <div :for={{kind, message} <- @flash}
         class={"flash flash-#{kind}"}
         role="alert">
      <%= render_slot(@inner_block, {kind, message}) %>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :title, :string, default: nil
  attr :message, :string, required: true

  def flash_message(assigns) do
    ~H"""
    <div class={"flash-message flash-#{@kind}"}>
      <p :if={@title} class="font-semibold"><%= @title %></p>
      <p><%= @message %></p>
    </div>
    """
  end

  ## Form Components

  attr :for, :any, required: true
  attr :as, :any, default: nil
  attr :rest, :global, include: ~w(action method)
  slot :inner_block, required: true

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="space-y-4">
        <%= render_slot(@inner_block, f) %>
      </div>
    </.form>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :type, :atom, default: :text
  attr :label, :string, default: nil
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <div class="flex flex-col gap-1">
      <label :if={@label} for={@field.id} class="text-sm font-medium text-zinc-700">
        <%= @label || Phoenix.Naming.humanize(@field.field) %>
      </label>
      <input :if={@type in [:text, :email, :password, :number]}
             type={@type}
             id={@field.id}
             name={@field.name}
             value={@field.value}
             class="input" {@rest} />
      <textarea :if={@type == :textarea}
                id={@field.id}
                name={@field.name}
                class="textarea" {@rest}><%= @field.value %></textarea>
      <p :for={msg <- List.wrap(@field.errors)} class="text-sm text-red-600">
        <%= translate_error(msg) %>
      </p>
    </div>
    """
  end

  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <.link :if={@navigate} navigate={@navigate} class="btn" {@rest}>
      <%= render_slot(@inner_block) %>
    </.link>
    <.link :if={@patch} patch={@patch} class="btn" {@rest}>
      <%= render_slot(@inner_block) %>
    </.link>
    <button :if={!@navigate and !@patch} type="submit" class="btn" {@rest}>
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  ## Header Component

  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-4">
      <div>
        <h1 class="text-2xl font-semibold text-zinc-900"><%= @title %></h1>
        <p :if={@subtitle} class="text-sm text-zinc-500"><%= @subtitle %></p>
      </div>
      <div class="flex items-center gap-2">
        <%= render_slot(@actions) %>
      </div>
    </header>
    """
  end

  ## Icon Component

  attr :name, :string, required: true
  attr :rest, :global

  def icon(assigns) do
    ~H"""
    <span class="material-icons" aria-hidden="true" {@rest}><%= @name %></span>
    """
  end

  ## Helper Functions

  def csrf_meta_tag(assigns) do
    assigns = assign(assigns, :csrf_token, CSRFProtection.get_csrf_token())

    ~H"""
    <meta name="csrf-token" content={@csrf_token} />
    """
  end

  def translate_error({msg, opts}) do
    Gettext.dgettext(MoneyTreeWeb.Gettext, "errors", msg, opts)
  end

  def translate_error(msg) when is_binary(msg), do: msg
end
