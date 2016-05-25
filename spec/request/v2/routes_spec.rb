require 'spec_helper'

describe 'Routes' do
  let(:user) { VCAP::CloudController::User.make }
  let(:space) { VCAP::CloudController::Space.make }

  before do
    space.organization.add_user(user)
    space.add_developer(user)

    stub_request(:post, 'http://routing-client:routing-secret@localhost:8080/uaa/oauth/token').
      with(body: 'grant_type=client_credentials').
      to_return(status: 200,
        body: '{"token_type": "monkeys", "access_token": "banana"}',
        headers: {'content-type' => 'application/json'})

    stub_request(:get, 'http://localhost:3000/routing/v1/router_groups').
      to_return(:status => 200, :body => '{}', :headers => {})
  end

  describe 'GET /v2/routes/:guid' do
    let!(:route) { VCAP::CloudController::Route.make(domain: domain, space: space) }

    context 'with a shared domain' do
      let(:domain) { VCAP::CloudController::SharedDomain.make(router_group_guid: 'tcp-group') }

      it 'maps domain_url to the shared domains controller' do
        get "/v2/routes/#{route.guid}", nil, headers_for(user)
        expect(last_response.status).to eq(200)

        parsed_response = MultiJson.load(last_response.body)
        expect(parsed_response['entity']['domain_url']).to eq("/v2/shared_domains/#{domain.guid}")
      end
    end

    context 'with a private domain' do
      let(:domain) { VCAP::CloudController::PrivateDomain.make(router_group_guid: 'tcp-group', owning_organization: space.organization) }

      it 'maps domain_url to the shared domains controller' do
        get "/v2/routes/#{route.guid}", nil, headers_for(user)
        expect(last_response.status).to eq(200)

        parsed_response = MultiJson.load(last_response.body)
        expect(parsed_response['entity']['domain_url']).to eq("/v2/private_domains/#{domain.guid}")
      end
    end
  end
end
