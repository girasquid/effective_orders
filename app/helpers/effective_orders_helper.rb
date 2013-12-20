module EffectiveOrdersHelper
  def order_summary(order)
    content_tag(:p, "#{number_to_currency(order.total)} total for #{order.num_items} items:") +

    content_tag(:ul) do
      order.order_items.map do |item|
        content_tag(:li) do
          "#{item.quantity}x #{item.title} for #{number_to_currency(item.price)}"
        end
      end.join().html_safe
    end
  end

  def order_item_summary(order_item)
    if order_item.quantity > 1
      content_tag(:p, "#{number_to_currency(order_item.total)} total for #{order_item.quantity}x items")
    else
      content_tag(:p, "#{number_to_currency(order_item.total)} total")
    end
  end

  # This is called on the My Sales Page and is intended to be overridden in the app if needed
  def acts_as_purchasable_path(purchasable, action = :show)
    polymorphic_path(purchasable)
  end

  def order_payment_to_html(order)
    payment = order.payment

    if order.purchased?(:stripe_connect) && order.payment.kind_of?(Hash)
      payment = Hash[
        order.payment.map do |seller_id, v|
          user = Effective::Customer.for_user(seller_id).user
          [link_to(user, admin_user_path(user)), order.payment[seller_id]]
        end
      ]

    end

    content_tag(:pre) do
      raw JSON.pretty_generate(payment).html_safe
        .gsub('\"', '')
        .gsub("[\n\n    ]", '[]')
        .gsub("{\n    }", '{}')
    end
  end

end
