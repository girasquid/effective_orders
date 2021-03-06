require 'spec_helper'

describe Admin::OrdersController, type: :controller do
  routes { EffectiveOrders::Engine.routes }

  let!(:user1) { FactoryGirl.create(:user, email: 'bbb@example.com') }
  let!(:user2) { FactoryGirl.create(:user, email: 'ccc@example.com') }
  let!(:user3) { FactoryGirl.create(:user, email: 'aaa@example.com') }
  let(:cart) { FactoryGirl.create(:cart, user: user1) }

  before { sign_in cart.user }

  describe 'GET #new' do
    it 'should render admin new order page successfully' do
      get :new

      expect(response).to be_successful
      expect(response).to render_template :new
      expect(assigns(:order)).to be_an Effective::Order
      expect(assigns(:order)).to be_new_record
      expect(assigns(:page_title)).to eq 'New Order'
    end
  end

  describe 'POST #create' do
    let(:user1) { FactoryGirl.create(:user, email: 'bbb@example.com', billing_address: FactoryGirl.create(:address), shipping_address: FactoryGirl.create(:address)) }

    context 'when success' do
      let(:order_params) { { effective_order: { user_id: user1.id, order_items_attributes: { '0' => { purchasable_attributes: { title: 'test product 1', price: '10000', tax_exempt: '1' }, quantity: '2', '_destroy' => 'false' }, '1' => { purchasable_attributes: { title: 'test product 2', price: '30000', tax_exempt: '0' }, quantity: '3', '_destroy' => 'false' } }, send_payment_request_to_buyer: '1' } } }

      shared_context 'creates objects in db correctly' do
        it 'should create new custom order with pending state' do
          expect { post :create, order_params.merge(commit: button_pressed) }.to change { Effective::Order.count }.from(0).to(1)

          expect(assigns(:order)).to be_persisted
          expect(assigns(:order).pending?).to be_truthy
          expect(assigns(:order).user).to eq user1
          expect(assigns(:order).billing_address).to eq user1.billing_address
          expect(assigns(:order).shipping_address).to eq user1.shipping_address

          expect(assigns(:order).order_items.count).to eq 2

          first_item = assigns(:order).order_items.sort.first
          expect(first_item).to be_persisted
          expect(first_item.title).to eq 'test product 1'
          expect(first_item.quantity).to eq 2
          expect(first_item.price).to eq 10000
          expect(first_item.tax_exempt).to be_truthy

          second_item = assigns(:order).order_items.sort.last
          expect(second_item).to be_persisted
          expect(second_item.title).to eq 'test product 2'
          expect(second_item.quantity).to eq 3
          expect(second_item.price).to eq 30000
          expect(second_item.tax_exempt).to be_falsey
        end

        it 'should create new effective products' do
          expect { post :create, order_params.merge(commit: button_pressed) }.to change { Effective::Product.count }.from(0).to(2)

          first_product = Effective::Product.all.sort.first
          expect(first_product.title).to eq 'test product 1'
          expect(first_product.price).to eq 10000

          second_product = Effective::Product.all.sort.last
          expect(second_product.title).to eq 'test product 2'
          expect(second_product.price).to eq 30000
        end
      end

      context 'when "Save" button is pressed' do
        let(:button_pressed) { 'Save' }

        it_should_behave_like 'creates objects in db correctly'

        it 'should redirect to admin orders index page with success message' do
          post :create, order_params.merge(commit: button_pressed)

          expect(response).to be_redirect
          expect(response).to redirect_to EffectiveOrders::Engine.routes.url_helpers.admin_order_path(assigns(:order))
          expect(flash[:success]).to eq "Successfully created order. #{assigns(:order).user.email} has been sent a request for payment."
        end
      end

      context 'when "Save and Add New" button is pressed' do
        let(:button_pressed) { 'Save and Add New' }

        it_should_behave_like 'creates objects in db correctly'

        it 'should redirect to admin new order page with success message' do
          post :create, order_params.merge(commit: button_pressed)

          expect(response).to be_redirect
          expect(response).to redirect_to EffectiveOrders::Engine.routes.url_helpers.new_admin_order_path(user_id: 1)
          expect(flash[:success]).to eq "Successfully created order. #{assigns(:order).user.email} has been sent a request for payment."
        end
      end
    end

    context 'when failed' do
      let(:order_params) { { effective_order: { user_id: user1.id, order_items_attributes: { '0' => { purchasable_attributes: { title: 'test product 1', price: '0', tax_exempt: '1' }, quantity: '2', '_destroy' => 'false' } } } } }

      shared_context 'does not create objects in db and redirects to admin new order page with danger message' do
        it 'should not create order' do
          expect { post :create, order_params.merge(commit: button_pressed) }.not_to change { Effective::Order.count }

          expect(assigns(:order)).to be_new_record
          expect(assigns(:order).valid?).to be_falsey
          expect(assigns(:order).pending?).to be_truthy
          expect(assigns(:order).user).to eq user1
          expect(assigns(:order).billing_address).to eq user1.billing_address
          expect(assigns(:order).shipping_address).to eq user1.shipping_address

          expect(assigns(:order).order_items.to_a.count).to eq 1

          item = assigns(:order).order_items.first
          expect(item).to be_new_record
          expect(item.valid?).to be_falsey
          expect(item.title).to eq 'test product 1'
          expect(item.quantity).to eq 2
          expect(item.price).to eq 0
          expect(item.tax_exempt).to be_truthy
        end

        it 'should not create product' do
          expect { post :create, order_params.merge(commit: button_pressed) }.not_to change { Effective::Product.count }
        end

        it 'should render admin new order page with danger message' do
          post :create, order_params.merge(commit: button_pressed)

          expect(response).to be_successful
          expect(response).to render_template :new
          expect(assigns(:page_title)).to eq 'New Order'
          expect(flash[:danger].to_s.include?('Unable to create order')).to eq true
        end
      end

      context 'when "Save" button is pressed' do
        let(:button_pressed) { 'Save' }

        it_should_behave_like 'does not create objects in db and redirects to admin new order page with danger message'
      end

      context 'when "Save and Add New" button is pressed' do
        let(:button_pressed) { 'Save and Add New' }

        it_should_behave_like 'does not create objects in db and redirects to admin new order page with danger message'
      end
    end
  end

  # This was changed to be a GET -> POST form, but it hasn't been updated in the test yet
  # describe 'POST #mark_as_paid' do
  #   let(:order) { FactoryGirl.create(:pending_order) }

  #   before { request.env['HTTP_REFERER'] = 'where_i_came_from' }

  #   context 'when success' do
  #     it 'should update order state and redirect to orders admin index page with success message' do
  #       post :mark_as_paid, id: order.to_param

  #       expect(response).to be_redirect
  #       expect(response).to redirect_to EffectiveOrders::Engine.routes.url_helpers.admin_order_path(assigns(:order))
  #       expect(assigns(:order)).to eq order
  #       expect(assigns(:order).purchased?).to be_truthy
  #       expect(assigns(:order).payment).to eq(details: 'Marked as paid by admin')
  #       expect(flash[:success]).to eq 'Order marked as paid successfully'
  #     end
  #   end

  #   context 'when failed' do
  #     before { Effective::Order.any_instance.stub(:purchase!).and_return(false) }

  #     it 'should redirect back with danger message' do
  #       post :mark_as_paid, id: order.to_param

  #       expect(response).to be_redirect
  #       expect(response).to redirect_to 'where_i_came_from'
  #       expect(assigns(:order)).to eq order
  #       expect(assigns(:order).purchased?).to be_falsey
  #       expect(flash[:danger]).to eq 'Unable to mark order as paid'
  #     end
  #   end
  # end

  describe 'POST #send_payment_request' do
    let(:user) { FactoryGirl.create(:user, email: 'user@example.com') }
    let(:order) { FactoryGirl.create(:order, user: user) }

    context 'when success' do
      before { Effective::Order.any_instance.should_receive(:send_payment_request_to_buyer!).once.and_return(true) }

      context 'when referrer page is present' do
        before { request.env['HTTP_REFERER'] = 'where_i_came_from' }

        it 'should redirect to previous page with success message' do
          post :send_payment_request, id: order.to_param

          expect(response).to be_redirect
          expect(response).to redirect_to 'where_i_came_from'
          expect(flash[:success]).to eq 'Successfully sent payment request to user@example.com'
        end
      end

      context 'when referrer page is not present' do
        it 'should redirect to admin order show page with success message' do
          post :send_payment_request, id: order.to_param

          expect(response).to be_redirect
          expect(response).to redirect_to EffectiveOrders::Engine.routes.url_helpers.admin_order_path(order)
          expect(flash[:success]).to eq 'Successfully sent payment request to user@example.com'
        end
      end
    end

    context 'when failed' do
      before { Effective::Order.any_instance.should_receive(:send_payment_request_to_buyer!).once.and_return(false) }

      context 'when referrer page is present' do
        before { request.env['HTTP_REFERER'] = 'where_i_came_from' }

        it 'should redirect to previous page with danger message' do
          post :send_payment_request, id: order.to_param

          expect(response).to be_redirect
          expect(response).to redirect_to 'where_i_came_from'
          expect(flash[:danger]).to eq 'Unable to send payment request'
        end
      end

      context 'when referrer page is not present' do
        it 'should redirect to admin order show page with danger message' do
          post :send_payment_request, id: order.to_param

          expect(response).to be_redirect
          expect(response).to redirect_to EffectiveOrders::Engine.routes.url_helpers.admin_order_path(order)
          expect(flash[:danger]).to eq 'Unable to send payment request'
        end
      end
    end
  end
end
