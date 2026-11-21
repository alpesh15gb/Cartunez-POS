<?php
declare(strict_types=1);

namespace Cartunez\Storefront\Setup\Patch\Data;

use Magento\Cms\Model\PageFactory;
use Magento\Cms\Model\ResourceModel\Page as PageResource;
use Magento\Framework\Setup\Patch\DataPatchInterface;

/**
 * Every published part is always orderable and the shop never talks about
 * stock, so the shipping policy drops its "available on order" and "parts in
 * stock" wording. Edits the page in place and only the exact launch sentences
 * (safe to run on a page an admin has changed).
 */
class AlwaysOrderable implements DataPatchInterface
{
    private const REPLACE = [
        ' Parts marked <em>available on order</em> ship in the number of days shown on the product page.' => '',
        'usually the same or next working day for parts in stock.' => 'usually the same or next working day.',
        '<p>Parts in stock are packed and handed to the courier' => '<p>Orders are packed and handed to the courier',
    ];

    public function __construct(
        private readonly PageFactory $pageFactory,
        private readonly PageResource $pageResource
    ) {
    }

    public function apply(): self
    {
        $page = $this->pageFactory->create();
        $this->pageResource->load($page, 'shipping-policy', 'identifier');
        if (!$page->getId()) {
            return $this;
        }
        $content = (string)$page->getContent();
        $updated = strtr($content, self::REPLACE);
        if ($updated !== $content) {
            $page->setContent($updated);
            $this->pageResource->save($page);
        }
        return $this;
    }

    public static function getDependencies(): array
    {
        return [PolicyPages::class];
    }

    public function getAliases(): array
    {
        return [];
    }
}
