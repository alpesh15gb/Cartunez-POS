<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\BlockFactory;
use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Block as BlockResource;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * The shop is not GST registered: takes every GST mention out of the home page,
 * offer bar, footer, trust strip and policy pages, and says "Invoice with every
 * order" where an invoice is mentioned. Only these phrases change; everything
 * else (and anything edited in the admin) stays. Running it again changes nothing.
 */
class RemoveGst implements DataPatchInterface
{
    private const PAGES = [
        'home', 'shipping-policy', 'returns-and-refunds', 'terms-and-conditions',
        'privacy-policy-cookie-restriction-mode',
    ];
    private const BLOCKS = ['cartunez-announcement', 'cartunez-footer', 'cartunez-hero'];

    /** Exact phrases written by the earlier patches, longest first. */
    private const REPLACE = [
        '<li><strong>GST invoice</strong><span>Prices include all taxes; invoice with every order.</span></li>'
            => '<li><strong>Invoice with every order</strong><span>Clear, fair prices on every part.</span></li>',
        '<li><strong>GST invoice</strong><span>Prices include all taxes</span></li>'
            => '<li><strong>Invoice with every order</strong><span>Clear, fair prices on every part</span></li>',
        'All prices are in Indian Rupees and include GST. A GST invoice is provided with every order.'
            => 'All prices are in Indian Rupees. An invoice is provided with every order.',
        'keep records required by law (including GST)' => 'keep records required by law',
        '<li>Prices include GST, invoice with every order</li>' => '<li>Invoice with every order</li>',
        '<li>GST invoice with every order</li>' => '<li>Invoice with every order</li>',
        'Shop online with GST invoice, pickup or delivery across India.' => 'Shop online with pickup or delivery across India.',
        ', GST invoice on every order' => ', invoice with every order',
        'GST invoice on every order' => 'Invoice with every order',
        'GST invoice with every order' => 'Invoice with every order',
    ];

    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly PageResource $pageResource,
        private readonly BlockFactory $blockFactory,
        private readonly BlockResource $blockResource
    ) {
    }

    public function apply(): self
    {
        foreach (self::PAGES as $id) {
            $page = $this->pageFactory->create();
            $this->pageResource->load($page, $id, 'identifier');
            if (!$page->getId()) {
                continue;
            }
            $content = (string)$page->getContent();
            $meta = (string)$page->getMetaDescription();
            $newContent = $this->clean($content);
            $newMeta = $this->clean($meta);
            if ($newContent !== $content || $newMeta !== $meta) {
                $page->setContent($newContent)->setMetaDescription($newMeta);
                $this->pageResource->save($page);
            }
        }
        foreach (self::BLOCKS as $id) {
            $block = $this->blockFactory->create();
            $this->blockResource->load($block, $id, 'identifier');
            if (!$block->getId()) {
                continue;
            }
            $content = (string)$block->getContent();
            $new = $this->clean($content);
            if ($new !== $content) {
                $block->setContent($new);
                $this->blockResource->save($block);
            }
        }
        return $this;
    }

    public function clean(string $html): string
    {
        $html = strtr($html, self::REPLACE);
        // Lines that only state GST ("All prices include GST", "GSTIN: ...") go.
        $html = (string)preg_replace('#[ \t]*<li>[^<]*\bGST(IN)?\b[^<]*</li>[ \t]*\R?#i', '', $html);
        $html = (string)preg_replace('#[ \t]*<p>[^<]*\bGSTIN\b[^<]*</p>[ \t]*\R?#i', '', $html);
        return $html;
    }

    public static function getDependencies(): array
    {
        return [PolicyPages::class, PremiumStoreContent::class, SaleSection::class, ShopDetails::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
