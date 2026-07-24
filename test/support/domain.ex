defmodule SearchAsh.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource SearchAsh.Test.Article do
      define(:create_article, action: :create)
      define(:update_article, action: :update)
      define(:search_articles, action: :search, args: [:query, :language])
    end

    resource SearchAsh.Test.SearchDocument do
      define(:global_search, action: :global_search, args: [:query, :language])
    end

    # Only `SearchAsh.GlobalIndex.Info.synonyms/2` reads this one's DSL (the MFA form); it
    # is never queried, so it needs no code interface and no table.
    resource SearchAsh.Test.SynonymMfaDocument

    # Same, for the per-resource side: `SearchAsh.Info.synonyms/2` reads the MFA form. Never
    # queried, no table.
    resource SearchAsh.Test.SynonymMfaArticle

    resource SearchAsh.Test.Product do
      define(:create_product, action: :create)
      define(:update_product, action: :update)
      define(:destroy_product, action: :destroy)
    end

    resource SearchAsh.Test.StaticPage do
      define(:create_static_page, action: :create)
      define(:update_static_page, action: :update)
    end

    resource SearchAsh.Test.SecuredDocument

    resource SearchAsh.Test.SecuredProduct do
      define :create_secured_product, action: :create
      define :destroy_secured_product, action: :destroy
    end

    resource SearchAsh.Test.SecuredInvoice do
      define :create_secured_invoice, action: :create
    end

    resource SearchAsh.Test.Invoice do
      define(:create_invoice, action: :create)
      define(:update_invoice, action: :update)
      define(:destroy_invoice, action: :destroy)
    end

    resource SearchAsh.Test.LineItem do
      define(:create_line_item, action: :create)
      define(:update_line_item, action: :update)
    end

    resource SearchAsh.Test.TrashableNote do
      define(:create_trashable_note, action: :create)
    end

    resource SearchAsh.Test.Ticket do
      define(:create_ticket, action: :create)
      define(:update_ticket, action: :update)
    end

    resource SearchAsh.Test.OffsetPage do
      define(:create_offset_page, action: :create)
    end

    resource SearchAsh.Test.FuzzyDocument do
      define(:fuzzy_search, action: :global_search, args: [:query, :language])
    end

    resource SearchAsh.Test.Contact do
      define(:create_contact, action: :create)
      define(:update_contact, action: :update)
    end

    resource SearchAsh.Test.Order do
      define(:create_order, action: :create)
      define(:update_order, action: :update)
      define(:destroy_order, action: :destroy)
    end

    resource SearchAsh.Test.OrderLine do
      define(:create_order_line, action: :create)
      define(:update_order_line, action: :update)
    end
  end
end
