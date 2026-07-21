defmodule SearchDemo.Sales do
  @moduledoc "Demo business domain (factures, clients, produits) that feeds the search index."
  use Ash.Domain

  resources do
    resource SearchDemo.Sales.Facture do
      define :create_facture, action: :create
      define :update_facture, action: :update
      define :destroy_facture, action: :destroy
    end

    resource SearchDemo.Sales.Ligne do
      define :create_ligne, action: :create
      define :update_ligne, action: :update
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
