module VCAP::CloudController
  class RouteMappingCreate
    class InvalidRouteMapping < StandardError; end

    DUPLICATE_MESSAGE     = 'a duplicate route mapping already exists'.freeze
    INVALID_SPACE_MESSAGE = 'the app and route must belong to the same space'.freeze

    def initialize(user, user_email)
      @user       = user
      @user_email = user_email
    end

    def add(app, route, process_model, message)
      validate_space!(app, route)

      route_mapping = RouteMappingModel.new(
        app:          app,
        route:        route,
        process_type: message.process_type,
        app_port:     message.app_port
      )

      RouteMappingModel.db.transaction do
        route_mapping.save

        if process_model
          RouteMapping.create(
            app:      process_model,
            route:    route,
            app_port: message.app_port
          )
        end

        app_event_repository.record_map_route(
          app,
          route,
          @user.try(:guid),
          @user_email,
          route_mapping: route_mapping
        )
      end

      route_mapping

    rescue Sequel::ValidationFailed => e
      if e.errors && e.errors.on([:app_guid, :route_guid, :process_type]) && e.errors.on([:app_guid, :route_guid, :process_type]).include?(:unique)
        raise InvalidRouteMapping.new(DUPLICATE_MESSAGE)
      end

      raise InvalidRouteMapping.new(e.message)
    end

    private

    def validate_space!(app, route)
      raise InvalidRouteMapping.new(INVALID_SPACE_MESSAGE) unless app.space.guid == route.space.guid
    end

    def app_event_repository
      Repositories::AppEventRepository.new
    end
  end
end
