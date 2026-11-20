<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * The shop's real address, phone and opening hours in the footer and offer bar.
 * Written once; edit later in Content > Blocks > cartunez-footer / cartunez-announcement.
 */
class ShopDetails implements DataPatchInterface
{
    public function __construct(
        private readonly BlockFactory $blockFactory,
        private readonly BlockResource $blockResource
    ) {
    }

    public function apply(): self
    {
        $this->save('cartunez-footer', $this->footer());
        $this->save('cartunez-announcement', '<div class="cz-announcement">'
            . 'Performance upgrades &middot; Interior makeovers &middot; Audio installation &middot; '
            . 'Call <a href="tel:+919949695030">099496 95030</a></div>');
        return $this;
    }

    private function save(string $id, string $content): void
    {
        $block = $this->blockFactory->create();
        $this->blockResource->load($block, $id, 'identifier');
        if (!$block->getId()) {
            $block->setIdentifier($id)->setTitle($id)->setStores([0])->setIsActive(1);
        }
        $block->setContent($content);
        $this->blockResource->save($block);
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
  </div>
  <div>
    <h4>Visit us</h4>
    <p>Shop No. 12 &amp; 13, Veer Hanuman Temple,<br>S.P. Road, Secunderabad,<br>Hyderabad, Telangana 500003</p>
    <p><a href="{$map}" target="_blank" rel="noopener">Get directions</a></p>
  </div>
  <div>
    <h4>Contact &amp; hours</h4>
    <ul>
      <li>Phone: <a href="tel:+919949695030">099496 95030</a></li>
      <li>Mon&ndash;Sat: 11 am &ndash; 10 pm</li>
      <li>Sunday: 11:30 am &ndash; 6 pm</li>
      <li>Hours may differ on holidays</li>
    </ul>
  </div>
  <div>
    <h4>Orders</h4>
    <ul>
      <li>All prices include GST</li>
      <li>GST invoice with every order</li>
      <li>Returns on unused parts with the invoice</li>
    </ul>
  </div>
</div>
HTML;
    }

    public static function getDependencies(): array
    {
        return [DarkStoreContent::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
