module Effective
  class OrdersMailer < ActionMailer::Base
    helper EffectiveOrdersHelper

    layout EffectiveOrders.mailer[:layout].presence || 'effective_orders_mailer_layout'

    def order_receipt_to_admin(order_param)
      @order = (order_param.kind_of?(Effective::Order) ? order_param : Effective::Order.find(order_param))

      mail(
        to: EffectiveOrders.mailer[:admin_email],
        from: EffectiveOrders.mailer[:default_from],
        subject: subject_for_order_receipt_to_admin(@order)
      )
    end

    def order_receipt_to_buyer(order_param)  # Buyer
      @order = (order_param.kind_of?(Effective::Order) ? order_param : Effective::Order.find(order_param))

      mail(
        to: @order.user.email,
        from: EffectiveOrders.mailer[:default_from],
        subject: subject_for_order_receipt_to_buyer(@order)
      )
    end

    def order_receipt_to_seller(order_param, seller, order_items)
      @order = (order_param.kind_of?(Effective::Order) ? order_param : Effective::Order.find(order_param))
      @user = seller.user
      @order_items = order_items
      @subject = subject_for_order_receipt_to_seller(@order, @order_items, seller.user)

      mail(
        to: @user.email,
        from: EffectiveOrders.mailer[:default_from],
        subject: @subject
      )
    end

    # This is sent when an admin creates a new order or /admin/orders/new
    # Or uses the order action Send Payment Request
    def payment_request_to_buyer(order_param)
      @order = (order_param.kind_of?(Effective::Order) ? order_param : Effective::Order.find(order_param))

      mail(
        to: @order.user.email,
        from: EffectiveOrders.mailer[:default_from],
        subject: subject_for_payment_request_to_buyer(@order)
      )
    end

    # This is sent when someone chooses to Pay by Cheque
    def pending_order_invoice_to_buyer(order_param)
      @order = (order_param.kind_of?(Effective::Order) ? order_param : Effective::Order.find(order_param))

      mail(
        to: @order.user.email,
        from: EffectiveOrders.mailer[:default_from],
        subject: subject_for_pending_order_invoice_to_buyer(@order)
      )
    end

    def order_error(order: nil, error: nil, to: nil, from: nil, subject: nil, template: 'order_error')
      if order.present?
        @order = (order.kind_of?(Effective::Order) ? order : Effective::Order.find(order))
        @subject = (subject || "An error occurred with order: ##{@order.try(:to_param)}")
      else
        @subject = (subject || "An order error occurred with an unknown order")
      end

      @error = error.to_s

      mail(
        to: (to || EffectiveOrders.mailer[:admin_email]),
        from: (from || EffectiveOrders.mailer[:default_from]),
        subject: prefix_subject(@subject),
      ) do |format|
        format.html { render(template) }
      end

    end

    private

    def subject_for_order_receipt_to_admin(order)
      string_or_callable = EffectiveOrders.mailer[:subject_for_order_receipt_to_admin]

      if string_or_callable.respond_to?(:call) # This is a Proc or a function, not a string
        string_or_callable = self.instance_exec(order, &string_or_callable)
      end

      prefix_subject(string_or_callable.presence || "Order Receipt: ##{order.to_param}")
    end

    def subject_for_order_receipt_to_buyer(order)
      string_or_callable = EffectiveOrders.mailer[:subject_for_order_receipt_to_buyer]

      if string_or_callable.respond_to?(:call) # This is a Proc or a function, not a string
        string_or_callable = self.instance_exec(order, &string_or_callable)
      end

      prefix_subject(string_or_callable.presence || "Order Receipt: ##{order.to_param}")
    end

    def subject_for_order_receipt_to_seller(order, order_items, seller)
      string_or_callable = EffectiveOrders.mailer[:subject_for_seller_receipt]

      if string_or_callable.respond_to?(:call) # This is a Proc or a function, not a string
        string_or_callable = self.instance_exec(order, order_items, seller, &string_or_callable)
      end

      prefix_subject(string_or_callable.presence || "#{order_items.length} of your products #{order_items.length > 1 ? 'have' : 'has'} been purchased")
    end

    def subject_for_payment_request_to_buyer(order)
      string_or_callable = EffectiveOrders.mailer[:subject_for_payment_request_to_buyer]

      if string_or_callable.respond_to?(:call) # This is a Proc or a function, not a string
        string_or_callable = self.instance_exec(order, &string_or_callable)
      end

      prefix_subject(string_or_callable.presence || "Request for Payment: Invoice ##{order.to_param}")
    end

    def subject_for_pending_order_invoice_to_buyer(order)
      string_or_callable = EffectiveOrders.mailer[:subject_for_pending_order_invoice_to_buyer]

      if string_or_callable.respond_to?(:call) # This is a Proc or a function, not a string
        string_or_callable = self.instance_exec(order, &string_or_callable)
      end

      prefix_subject(string_or_callable.presence || "Pending Order: ##{order.to_param}")
    end


    def prefix_subject(text)
      prefix = (EffectiveOrders.mailer[:subject_prefix].to_s rescue '')
      prefix.present? ? (prefix.chomp(' ') + ' ' + text) : text
    end
  end
end
