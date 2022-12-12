defmodule LightningWeb.RunLive.Index do
  @moduledoc """
  Index Liveview for Runs
  """
  use LightningWeb, :live_view

  alias Lightning.{AttemptService, Invocation, RunSearchForm, Pipeline}
  alias Lightning.Invocation.Run

  alias Lightning.RunSearchForm
  alias Lightning.RunSearchForm.MultiSelectOption

  on_mount {LightningWeb.Hooks, :project_scope}

  @impl true
  def mount(_params, _session, socket) do
    statuses = [
      %MultiSelectOption{id: :success, label: "Success", selected: true},
      %MultiSelectOption{id: :failure, label: "Failure", selected: true},
      %MultiSelectOption{id: :timeout, label: "Timeout", selected: true},
      %MultiSelectOption{id: :crash, label: "Crash", selected: true},
      %MultiSelectOption{id: :pending, label: "Pending", selected: true}
    ]

    searchfors = [
      %MultiSelectOption{id: :body, label: "Input body", selected: true},
      %MultiSelectOption{id: :log, label: "Logs", selected: true}
    ]

    LightningWeb.Endpoint.subscribe("workorder:#{socket.assigns.project.id}")

    workflows =
      Lightning.Workflows.get_workflows_for(socket.assigns.project)
      |> Enum.map(&{&1.name || "Untitled", &1.id})

    {:ok,
     socket
     |> assign(
       active_menu_item: :runs,
       work_orders: [],
       pagination_path:
         &Routes.project_run_index_path(
           socket,
           :index,
           socket.assigns.project,
           &1
         )
     )
     |> init_search_form(
       statuses: statuses,
       searchfors: searchfors,
       workflows: workflows
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(
       page_title: "Runs",
       run: %Run{}
     )
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    changeset = socket.assigns.changeset

    socket
    |> assign(
      status_options: Ecto.Changeset.fetch_field!(changeset, :status_options),
      searchfor_options:
        Ecto.Changeset.fetch_field!(changeset, :searchfor_options),
      page:
        Invocation.list_work_orders_for_project(
          socket.assigns.project,
          build_filter(changeset),
          params
        )
    )
  end

  @impl true
  def handle_info({:selected_statuses, statuses}, socket) do
    changeset =
      socket.assigns.changeset
      |> Ecto.Changeset.put_embed(:status_options, statuses)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:status_options, statuses)

    {:noreply,
     socket
     |> push_patch(
       to: Routes.project_run_index_path(socket, :index, socket.assigns.project)
     )}
  end

  def handle_info({:selected_searchfors, searchfors}, socket) do
    changeset =
      socket.assigns.changeset
      |> Ecto.Changeset.put_embed(:searchfor_options, searchfors)

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:searchfor_options, searchfors)

    {:noreply, socket}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "new_attempt",
          payload: %{work_order_id: work_order_id}
        },
        socket
      ) do
    send_update(LightningWeb.RunLive.WorkOrderComponent,
      id: work_order_id,
      event: "new_attempt"
    )

    {:noreply, socket}
  end

  @impl true
  def handle_event(
        "rerun",
        %{"attempt_id" => attempt_id, "run_id" => run_id},
        socket
      ) do
    %{attempt: attempt, run: run} =
      AttemptService.get_for_rerun(attempt_id, run_id)

    reason =
      Lightning.InvocationReasons.build(:retry, %{
        user: socket.assigns.current_user,
        run: run
      })

    {:ok, attempt_run} = AttemptService.retry(attempt, run, reason)

    Pipeline.new(%{attempt_run_id: attempt_run.id})
    |> Oban.insert()

    LightningWeb.Endpoint.broadcast!(
      "workorder:#{socket.assigns.project.id}",
      "new_attempt",
      %{work_order_id: attempt.work_order_id}
    )

    {:noreply, socket}
  end

  def handle_event(
        "validate",
        %{
          "run_search_form" => %{
            "workflow_id" => workflow_id,
            "date_after" => date_after,
            "date_before" => date_before
          }
        },
        socket
      ) do
    changeset =
      socket.assigns.changeset
      |> Ecto.Changeset.put_change(:workflow_id, workflow_id)
      |> Ecto.Changeset.put_change(:date_after, date_after)
      |> Ecto.Changeset.put_change(:date_before, date_before)

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply,
     socket
     |> push_patch(
       to: Routes.project_run_index_path(socket, :index, socket.assigns.project)
     )}
  end

  # NOTE: this event was previously called "ignore", however there is an
  # issue with form recovery in LiveView where only the first input (if it has
  # a `phx-change` on it) is sent.
  # https://github.com/phoenixframework/phoenix_live_view/issues/2333
  # We have changed the event name to "validate" since that is what
  # the form recovery event will use.
  def handle_event(
        "validate",
        %{"run_search_form" => %{"search_term" => search_term}},
        socket
      ) do
    changeset =
      socket.assigns.changeset
      |> Ecto.Changeset.put_change(:search_term, search_term)

    socket =
      socket
      |> assign(:changeset, changeset)

    {:noreply, socket}
  end

  defp init_search_form(socket,
         statuses: statuses,
         searchfors: searchfors,
         workflows: workflows
       ) do
    changeset =
      %RunSearchForm{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:status_options, statuses)
      |> Ecto.Changeset.put_embed(:searchfor_options, searchfors)

    socket
    |> assign(:changeset, changeset)
    |> assign(:workflows, workflows)
  end

  # return a keyword  list of criteria:value
  defp build_filter(changeset) do
    status =
      Ecto.Changeset.fetch_field!(changeset, :status_options)
      |> Enum.filter(&(&1.selected in [true, "true"]))
      |> Enum.map(& &1.id)

    searchfors =
      Ecto.Changeset.fetch_field!(changeset, :searchfor_options)
      |> Enum.filter(&(&1.selected in [true, "true"]))
      |> Enum.map(& &1.id)

    [
      status: status,
      searchfors: searchfors,
      search_term: Ecto.Changeset.fetch_field!(changeset, :search_term),
      workflow_id: Ecto.Changeset.fetch_field!(changeset, :workflow_id),
      date_after: Ecto.Changeset.fetch_field!(changeset, :date_after),
      date_before: Ecto.Changeset.fetch_field!(changeset, :date_before)
    ]
  end
end
