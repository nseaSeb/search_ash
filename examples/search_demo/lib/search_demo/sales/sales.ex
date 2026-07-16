defmodule SearchDemo.Sales do
  @moduledoc "Demo business domain (factures, clients, produits) that feeds the search index."
  use Ash.Domain

  resources do
    resource SearchDemo.Sales.Facture do
      define :create_facture, action: :create
      define :destroy_facture, action: :destroy
    end

    resource SearchDemo.Sales.Client do
      define :create_client, action: :create
      define :destroy_client, action: :destroy
    end

    resource SearchDemo.Sales.Produit do
      define :create_produit, action: :create
      define :destroy_produit, action: :destroy
    end
  end
end
