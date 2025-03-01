defmodule Glific.Messages.MessageMedia do
  @moduledoc """
  Message media are mapped with a message
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias __MODULE__

  alias Glific.{
    Enums.MessageFlow,
    Messages.MessageMedia,
    Partners.Organization
  }

  # define all the required fields for message media
  @required_fields [
    :url,
    :flow,
    :source_url,
    :organization_id
  ]

  # define all the optional fields for message media
  @optional_fields [
    :thumbnail,
    :provider_media_id,
    :caption,
    :gcs_url,
    :content_type
  ]

  @type t() :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: non_neg_integer | nil,
          url: String.t() | nil,
          content_type: String.t() | nil,
          source_url: String.t() | nil,
          caption: String.t() | nil,
          thumbnail: String.t() | nil,
          provider_media_id: String.t() | nil,
          inserted_at: :utc_datetime | nil,
          updated_at: :utc_datetime | nil,
          gcs_url: String.t() | nil,
          organization_id: non_neg_integer | nil,
          organization: Organization.t() | Ecto.Association.NotLoaded.t() | nil,
          flow: String.t() | nil
        }

  schema "messages_media" do
    field(:url, :string)
    field(:source_url, :string)
    field(:thumbnail, :string)
    field(:caption, :string)
    field(:provider_media_id, :string)
    field(:gcs_url, :string)
    field(:content_type, :string)
    field(:flow, MessageFlow)

    belongs_to(:organization, Organization)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Standard changeset pattern we use for all data types
  """
  @spec changeset(MessageMedia.t(), map()) :: Ecto.Changeset.t()
  def changeset(message_media, attrs) do
    message_media
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
