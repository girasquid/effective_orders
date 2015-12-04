module EffectiveOrders
  class Engine < ::Rails::Engine
    engine_name 'effective_orders'

    config.autoload_paths += Dir["#{config.root}/app/models/**/"]

    # Include Helpers to base application
    initializer 'effective_orders.action_controller' do |app|
      ActiveSupport.on_load :action_controller do
        helper EffectiveOrdersHelper
        helper EffectiveCartsHelper
        helper EffectivePaypalHelper if EffectiveOrders.paypal_enabled
        helper EffectiveStripeHelper if EffectiveOrders.stripe_enabled
      end
    end

    # Include acts_as_addressable concern and allow any ActiveRecord object to call it
    initializer 'effective_orders.active_record' do |app|
      ActiveSupport.on_load :active_record do
        ActiveRecord::Base.extend(ActsAsPurchasable::ActiveRecord)
      end
    end

    initializer 'effective_orders.action_view' do |app|
      ActiveSupport.on_load :action_view do
        ActionView::Helpers::FormBuilder.send(:include, Inputs::PriceFormInput)
      end
    end

    # Set up our default configuration options.
    initializer "effective_orders.defaults", :before => :load_config_initializers do |app|
      eval File.read("#{config.root}/lib/generators/templates/effective_orders.rb")
    end

    # Set up our Stripe API Key
    initializer "effective_orders.stripe_api_key", :after => :load_config_initializers do |app|
      if EffectiveOrders.stripe_enabled
        begin
          require 'stripe'
        rescue Exception
          raise "unable to load stripe.  Plese add gem 'stripe' to your Gemfile and then 'bundle install'"
        end

        ::Stripe.api_key = EffectiveOrders.stripe[:secret_key]
      end
    end

    initializer 'effective_orders.paypal_config_validation', :after => :load_config_initializers do
      if EffectiveOrders.paypal_enabled
        missing = EffectiveOrders.paypal.select do |config, value|
          value.blank?
        end

        raise "Missing effective_orders PayPal configuration values: #{missing.keys.join(', ')}" if missing.present?
      end
    end

    initializer 'effective_orders.default_configs', :after => :load_config_initializers do
      unless EffectiveOrders.mailer[:deliver_method].present?
        EffectiveOrders.mailer[:deliver_method] = case
                              when Rails.gem_version >= Gem::Version.new('4.2')
                                :deliver_now
                              else
                                :deliver
                              end
      end
    end

    # Use ActiveAdmin (optional)
    initializer 'effective_orders.active_admin' do
      if EffectiveOrders.use_active_admin?
        begin
          require 'activeadmin'
        rescue Exception
          raise "unable to load activeadmin.  Plese add gem 'activeadmin' to your Gemfile and then 'bundle install'"
        end

        ActiveAdmin.application.load_paths.unshift Dir["#{config.root}/active_admin"]

        Rails.application.config.to_prepare do
          ActiveSupport.on_load :action_controller do
            ApplicationController.extend(ActsAsActiveAdminController::ActionController)
            Effective::OrdersController.send(:acts_as_active_admin_controller, 'orders')
            Effective::CartsController.send(:acts_as_active_admin_controller, 'carts')
          end
        end

      end
    end

  end
end
