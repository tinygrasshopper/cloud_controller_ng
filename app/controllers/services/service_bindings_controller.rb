require 'services/api'

module VCAP::CloudController
  class ServiceBindingsController < RestController::ModelController
    define_attributes do
      to_one :app
      to_one :service_instance
      attribute :binding_options, Hash, default: {}
    end

    get path,      :enumerate
    get path_guid, :read

    query_parameters :app_guid, :service_instance_guid

    def self.dependencies
      [:services_event_repository]
    end

    def inject_dependencies(dependencies)
      super
      @services_event_repository = dependencies.fetch(:services_event_repository)
    end

    post path, :create
    def create
      @request_attrs = self.class::CreateMessage.decode(body).extract(stringify_keys: true)

      logger.debug 'cc.create', model: self.class.model_class_name, attributes: request_attrs

      raise InvalidRequest unless request_attrs

      service_instance = ServiceInstance.find(guid: @request_attrs['service_instance_guid'])
      raise VCAP::Errors::ApiError.new_from_details('ServiceInstanceNotFound', @request_attrs['service_instance_guid']) unless service_instance
      raise VCAP::Errors::ApiError.new_from_details('UnbindableService') unless service_instance.bindable?
      validate_app(request_attrs['app_guid'])

      service_binding = ServiceBinding.new(@request_attrs)
      validate_access(:create, service_binding)
      raise Sequel::ValidationFailed.new(service_binding) if !service_binding.valid?

      begin
        lock_service_instance_by_blocking(service_instance) do
          attributes_to_update = service_binding.client.bind(service_binding)
          service_binding.set_all(attributes_to_update)
          service_binding.save
        end
      rescue
        service_binding.client.orphan_mitigator.cleanup_failed_bind(
          service_binding.client.attrs,
          service_binding
        )
        raise
      end

      @services_event_repository.record_service_binding_event(:create, service_binding)

      [HTTP::CREATED,
       { 'Location' => "#{self.class.path}/#{service_binding.guid}" },
       object_renderer.render_json(self.class, service_binding, @opts)
      ]
    end

    delete path_guid, :delete
    def delete(guid)
      service_binding = find_guid_and_validate_access(:delete, guid, ServiceBinding)
      raise_if_has_associations!(service_binding) if v2_api? && !recursive?

      service_instance = ServiceInstance.find(guid: service_binding.service_instance_guid)

      lock_service_instance_by_blocking(service_instance) do
        deletion_job = Jobs::Runtime::ModelDeletion.new(ServiceBinding, guid)
        delete_and_audit_job = Jobs::AuditEventJob.new(deletion_job, @services_event_repository, :record_service_binding_event, :delete, service_binding)

        enqueue_deletion_job(delete_and_audit_job)
      end
    end

    private

    def lock_service_instance_by_blocking(service_instance, &block)
      if service_instance.managed_instance?
        service_instance.lock_by_blocking_other_operations(&block)
      else
        block.call
      end
    end

    def validate_app(app_guid)
      app = App.find(guid: app_guid)
      raise VCAP::Errors::ApiError.new_from_details('AppNotFound', app_guid) unless app
    end

    def self.translate_validation_exception(e, attributes)
      unique_errors = e.errors.on([:app_id, :service_instance_id])
      if unique_errors && unique_errors.include?(:unique)
        Errors::ApiError.new_from_details('ServiceBindingAppServiceTaken', "#{attributes['app_guid']} #{attributes['service_instance_guid']}")
      elsif e.errors.on(:app) && e.errors.on(:app).include?(:presence)
        Errors::ApiError.new_from_details('AppNotFound', attributes['app_guid'])
      elsif e.errors.on(:service_instance) && e.errors.on(:service_instance).include?(:presence)
        Errors::ApiError.new_from_details('ServiceInstanceNotFound', attributes['service_instance_guid'])
      else
        Errors::ApiError.new_from_details('ServiceBindingInvalid', e.errors.full_messages)
      end
    end

    define_messages
  end
end
