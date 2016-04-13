Sequel.migration do
  change do
    add_column :route_mappings, :app_port, Integer, default: nil
  end
end
