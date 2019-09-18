# frozen_string_literal: true

module PuppetLanguageServer
  class LanguageClient
    attr_reader :message_router

    def initialize(message_router)
      @message_router = message_router
      @client_capabilites = {}

      # Internal registry of dynamic registrations and their current state
      # @registrations[ <[String] method_name>] = [
      #  {
      #    :id         => [String] Request ID. Used for de-registration
      #    :registered => [Boolean] true | false
      #    :state      => [Enum] :pending | :complete
      #   }
      # ]
      @registrations = {}
    end

    def client_capability(*names)
      safe_hash_traverse(@client_capabilites, *names)
    end

    def send_configuration_request
      params = LSP::ConfigurationParams.new.from_h!('items' => [])
      params.items << LSP::ConfigurationItem.new.from_h!('section' => 'puppet')

      message_router.json_rpc_handler.send_client_request('workspace/configuration', params)
      true
    end

    def parse_lsp_initialize!(initialize_params = {})
      @client_capabilites = initialize_params['capabilities']
    end

    # Settings could be a hash or an array of hash
    def parse_lsp_configuration_settings!(settings = [{}])
      # TODO: Future use. Actually do something with the settings
      # settings = [settings] unless settings.is_a?(Hash)
      # settings.each do |hash|
      # end
    end

    def capability_registrations(method)
      return [{ :registered => false, :state => :complete }] if @registrations[method].nil? || @registrations[method].empty?
      @registrations[method].dup
    end

    def register_capability(method, options = {})
      id = new_request_id

      PuppetLanguageServer.log_message(:info, "Attempting to dynamically register the #{method} method with id #{id}")

      if @registrations[method] && @registrations[method].select { |i| i[:state] == :pending }.count > 0
        # The protocol doesn't specify whether this is allowed and is probably per client specific. For the moment we will allow
        # the registration to be sent but log a message that something may be wrong.
        PuppetLanguageServer.log_message(:warn, "A dynamic registration/deregistration for the #{method} method is already in progress")
      end

      params = LSP::RegistrationParams.new.from_h!('registrations' => [])
      params.registrations << LSP::Registration.new.from_h!('id' => id, 'method' => method, 'registerOptions' => options)
      # Note - Don't put more than one method per request even though you can.  It makes decoding errors much harder!

      @registrations[method] = [] if @registrations[method].nil?
      @registrations[method] << { :registered => false, :state => :pending, :id => id }

      message_router.json_rpc_handler.send_client_request('client/registerCapability', params)
      true
    end

    def unregister_capability(method)
      if @registrations[method].nil?
        PuppetLanguageServer.log_message(:debug, "No registrations to deregister for the #{method}")
        return true
      end

      params = LSP::UnregistrationParams.new.from_h!('unregisterations' => [])
      @registrations[method].each do |reg|
        next if reg[:id].nil?
        PuppetLanguageServer.log_message(:warn, "A dynamic registration/deregistration for the #{method} method, with id #{reg[:id]} is already in progress") if reg[:state] == :pending
        # Ignore registrations that don't need to be unregistered
        next if reg[:state] == :complete && !reg[:registered]
        params.unregisterations << LSP::Unregistration.new.from_h!('id' => reg[:id], 'method' => method)
        reg[:state] = :pending
      end

      if params.unregisterations.count.zero?
        PuppetLanguageServer.log_message(:debug, "Nothing to deregister for the #{method} method")
        return true
      end

      message_router.json_rpc_handler.send_client_request('client/unregisterCapability', params)
      true
    end

    def parse_register_capability_response!(response, original_request)
      raise 'Response is not from client/registerCapability request' unless original_request['method'] == 'client/registerCapability'

      unless response.key?('result')
        original_request['params'].registrations.each do |reg|
          # Mark the registration as completed and failed
          @registrations[reg.method__lsp] = [] if @registrations[reg.method__lsp].nil?
          @registrations[reg.method__lsp].select { |i| i[:id] == reg.id }.each { |i| i[:registered] = false; i[:state] = :complete } # rubocop:disable Style/Semicolon This is fine
        end
        return true
      end

      original_request['params'].registrations.each do |reg|
        PuppetLanguageServer.log_message(:info, "Succesfully dynamically registered the #{reg.method__lsp} method")

        # Mark the registration as completed and succesful
        @registrations[reg.method__lsp] = [] if @registrations[reg.method__lsp].nil?
        @registrations[reg.method__lsp].select { |i| i[:id] == reg.id }.each { |i| i[:registered] = true; i[:state] = :complete } # rubocop:disable Style/Semicolon This is fine

        # If we just registered the workspace/didChangeConfiguration method then
        # also trigger a configuration request to get the initial state
        send_configuration_request if reg.method__lsp == 'workspace/didChangeConfiguration'
      end

      true
    end

    def parse_unregister_capability_response!(response, original_request)
      raise 'Response is not from client/unregisterCapability request' unless original_request['method'] == 'client/unregisterCapability'

      unless response.key?('result')
        original_request['params'].unregisterations.each do |reg|
          # Mark the registration as completed and failed
          @registrations[reg.method__lsp] = [] if @registrations[reg.method__lsp].nil?
          @registrations[reg.method__lsp].select { |i| i[:id] == reg.id && i[:registered] }.each { |i| i[:state] = :complete }
          @registrations[reg.method__lsp].delete_if { |i| i[:id] == reg.id && !i[:registered] }
        end
        return true
      end

      original_request['params'].unregisterations.each do |reg|
        PuppetLanguageServer.log_message(:info, "Succesfully dynamically unregistered the #{reg.method__lsp} method")

        # Remove registrations
        @registrations[reg.method__lsp] = [] if @registrations[reg.method__lsp].nil?
        @registrations[reg.method__lsp].delete_if { |i| i[:id] == reg.id }
      end

      true
    end

    private

    def new_request_id
      SecureRandom.uuid
    end

    def safe_hash_traverse(hash, *names)
      return nil if names.empty?
      item = nil
      loop do
        name = names.shift
        item = item.nil? ? hash[name] : item[name]
        return nil if item.nil?
        return item if names.empty?
      end
      nil
    end
  end
end
