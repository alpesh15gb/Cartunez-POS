<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Launch pages: shipping, returns and refunds, terms, privacy, plus footer links
 * and the offer bar. Written once; edit in Content > Pages and Content > Blocks.
 * They describe the launch setup (cash on delivery / UPI, free pickup, Rs 99
 * delivery free from Rs 1,999); change them if those settings change.
 */
class PolicyPages implements DataPatchInterface
{
    private const SELLER = 'Car Tunez, Shop No. 12 &amp; 13, Veer Hanuman Temple, S.P. Road, '
        . 'Secunderabad, Hyderabad, Telangana 500003. Phone: <a href="tel:+919949695030">099496 95030</a>.';

    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly PageResource $pageResource,
        private readonly BlockFactory $blockFactory,
        private readonly BlockResource $blockResource
    ) {
    }

    public function apply(): self
    {
        $this->page('shipping-policy', 'Shipping and delivery', $this->shipping());
        $this->page('returns-and-refunds', 'Returns and refunds', $this->returns());
        $this->page('terms-and-conditions', 'Terms and conditions', $this->terms());
        $this->page('privacy-policy-cookie-restriction-mode', 'Privacy policy', $this->privacy());
        $this->block('cartunez-footer', $this->footer());
        $this->block('cartunez-announcement', '<div class="cz-announcement">'
            . 'Free delivery above &#8377;1,999 &middot; Cash on delivery &middot; Free pickup in Secunderabad &middot; '
            . 'Call <a href="tel:+919949695030">099496 95030</a></div>');
        return $this;
    }

    private function page(string $id, string $title, string $content): void
    {
        $page = $this->pageFactory->create();
        $this->pageResource->load($page, $id, 'identifier');
        if (!$page->getId()) {
            $page->setIdentifier($id)->setStores([0]);
        }
        $page->setTitle($title)->setContentHeading($title)->setPageLayout('1column')
            ->setIsActive(1)
            ->setContent('<div class="cz-policy">' . str_replace('SELLER', self::SELLER, $content) . '</div>');
        $this->pageResource->save($page);
    }

    private function block(string $id, string $content): void
    {
        $block = $this->blockFactory->create();
        $this->blockResource->load($block, $id, 'identifier');
        if (!$block->getId()) {
            $block->setIdentifier($id)->setTitle($id)->setStores([0])->setIsActive(1);
        }
        $block->setContent($content);
        $this->blockResource->save($block);
    }

    private function shipping(): string
    {
        return <<<HTML
<h2>Ways to get your order</h2>
<ul>
  <li><strong>Store pickup (free):</strong> collect from our Secunderabad shop. We call or message you when the order is ready, usually the same or next working day for parts in stock.</li>
  <li><strong>Home delivery, all over India:</strong> &#8377;99 per order, <strong>free on orders of &#8377;1,999 or more</strong>.</li>
</ul>
<h2>When it ships</h2>
<p>Parts in stock are packed and handed to the courier within 1&ndash;2 working days of the order (after payment is confirmed for UPI orders). Delivery usually takes 2&ndash;4 days in Hyderabad and 3&ndash;8 days elsewhere in India. Parts marked <em>available on order</em> ship in the number of days shown on the product page.</p>
<p>We share the courier name and tracking number by SMS, WhatsApp or email once the parcel is dispatched.</p>
<h2>Damaged or wrong parcel</h2>
<p>Please check the parcel when it arrives. If it is damaged, or the part is not what you ordered, tell us within 48 hours with photos and we will replace it or refund you.</p>
<h2>Questions</h2>
<p>Call or WhatsApp 099496 95030, or <a href="{{store url="contact"}}">send us a message</a>.</p>
<p>Seller: SELLER</p>
HTML;
    }

    private function returns(): string
    {
        return <<<HTML
<h2>Returns</h2>
<p>You can return a part within <strong>7 days of delivery or pickup</strong> if it is unused, uninstalled and in its original packing, with the invoice.</p>
<p>We cannot take back:</p>
<ul>
  <li>parts that have been fitted, installed or used, or whose seals or packing are broken;</li>
  <li>electrical and electronic parts once connected (bulbs, sensors, ECUs, audio and wiring);</li>
  <li>fluids, oils and chemicals once opened;</li>
  <li>parts ordered specially for you (marked <em>available on order</em>), unless they arrive faulty or wrong.</li>
</ul>
<p>If a part is wrong for your vehicle because of our mistake, or arrives damaged or faulty, we replace it or refund it in full, including delivery charges.</p>
<h2>How to return</h2>
<p>Call or WhatsApp us on 099496 95030 with your order number. Bring the part to our shop, or we will tell you how to send it back.</p>
<h2>Refunds</h2>
<p>Once we receive and check the part, we refund within 7 working days: to your UPI or bank account for prepaid and cash on delivery orders, or in cash at the shop. Delivery charges are refunded only when the return is due to our mistake.</p>
<h2>Cancellations</h2>
<p>You can cancel free of charge until the order is dispatched or ready for pickup. Any amount paid is refunded within 7 working days.</p>
<p>Seller: SELLER</p>
HTML;
    }

    private function terms(): string
    {
        return <<<HTML
<p>These terms apply to orders placed on shop.cartunez.in. By placing an order you agree to them.</p>
<h2>Seller</h2>
<p>SELLER</p>
<h2>Prices and payment</h2>
<p>All prices are in Indian Rupees and include GST. A GST invoice is provided with every order. You can pay cash on delivery or at pickup, or by UPI before dispatch. We may cancel and fully refund an order if a price or stock error is found.</p>
<h2>Fitment</h2>
<p>We describe parts and the vehicles they fit as accurately as we can. Please check the part number or ask us before ordering if you are unsure; we are happy to confirm the right part for your vehicle. Installation should be done by a qualified mechanic.</p>
<h2>Warranty</h2>
<p>Parts carry the manufacturer's warranty where one is offered. Warranty claims are handled under the manufacturer's terms; we help you make the claim.</p>
<h2>Delivery, returns and refunds</h2>
<p>See our <a href="{{store url="shipping-policy"}}">shipping policy</a> and <a href="{{store url="returns-and-refunds"}}">returns and refunds policy</a>.</p>
<h2>Grievances</h2>
<p>For any complaint, contact our grievance officer (the store manager) at the shop or on 099496 95030, Monday to Saturday 11 am to 10 pm. We acknowledge complaints within 48 hours and resolve them within one month.</p>
<h2>Law</h2>
<p>These terms are governed by the laws of India. Courts in Hyderabad, Telangana have jurisdiction.</p>
HTML;
    }

    private function privacy(): string
    {
        return <<<HTML
<p>This policy explains what Car Tunez collects when you use shop.cartunez.in and how we use it.</p>
<h2>What we collect</h2>
<ul>
  <li>Your name, phone number, email and addresses when you order or create an account.</li>
  <li>Your orders and messages to us.</li>
  <li>Basic technical data (IP address, browser) and cookies needed for the cart, sign-in and security.</li>
</ul>
<p>We do not store card details. UPI payments are made in your own UPI app.</p>
<h2>How we use it</h2>
<p>To process and deliver your orders, send order updates, provide invoices and after-sales support, keep records required by law (including GST), and protect the shop against fraud.</p>
<h2>Who we share it with</h2>
<p>Only with those who help us fulfil your order: courier partners (name, phone and address), and our hosting and email providers. We do not sell your data.</p>
<h2>Your choices</h2>
<p>You can view and update your details in your account, or ask us to correct or delete them by calling 099496 95030 or through the contact page. Some records must be kept for tax law.</p>
<h2>Contact</h2>
<p>SELLER</p>
HTML;
    }

    private function footer(): string
    {
        $map = 'https://www.google.com/maps/search/?api=1&amp;query='
            . 'Car+Tunez+Veer+Hanuman+Temple+S.P.+Road+Secunderabad+500003';
        return <<<HTML
<div class="cz-footer">
  <div>
    <h4>Car Tunez</h4>
    <p>Car accessories, performance upgrades, interior makeovers and audio system installation.</p>
    <p>Shop No. 12 &amp; 13, Veer Hanuman Temple,<br>S.P. Road, Secunderabad,<br>Hyderabad, Telangana 500003</p>
    <p><a href="{$map}" target="_blank" rel="noopener">Get directions</a></p>
  </div>
  <div>
    <h4>Contact &amp; hours</h4>
    <ul>
      <li>Phone: <a href="tel:+919949695030">099496 95030</a></li>
      <li><a href="{{store url="contact"}}">Send us a message</a></li>
      <li>Mon&ndash;Sat: 11 am &ndash; 10 pm</li>
      <li>Sunday: 11:30 am &ndash; 6 pm</li>
    </ul>
  </div>
  <div>
    <h4>Orders</h4>
    <ul>
      <li>Cash on delivery or UPI</li>
      <li>Free pickup &middot; &#8377;99 delivery, free from &#8377;1,999</li>
      <li>Prices include GST, invoice with every order</li>
    </ul>
  </div>
  <div>
    <h4>Policies</h4>
    <ul>
      <li><a href="{{store url="shipping-policy"}}">Shipping and delivery</a></li>
      <li><a href="{{store url="returns-and-refunds"}}">Returns and refunds</a></li>
      <li><a href="{{store url="terms-and-conditions"}}">Terms and conditions</a></li>
      <li><a href="{{store url="privacy-policy-cookie-restriction-mode"}}">Privacy policy</a></li>
    </ul>
  </div>
</div>
HTML;
    }

    public static function getDependencies(): array
    {
        return [ShopDetails::class, BrandSection::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
